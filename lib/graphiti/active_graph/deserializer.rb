module Graphiti::ActiveGraph
  class Deserializer < Graphiti::Deserializer
    include Concerns::PathRelationships

    class Conflict < StandardError
      attr_reader :key, :path_value, :body_value

      def initialize(key, path_value, body_value)
        @key = key
        @path_value = path_value
        @body_value = body_value
      end

      def message
        "Path parameter #{key} with value '#{path_value}' conflicts with payload value '#{body_value}'"
      end
    end

    def initialize(payload, env = nil, model = nil, parent_map = nil)
      super(payload)

      @params = payload
      @model = model
      @parent_map = parent_map || {}
      @env = env

      return unless data.blank? && env && parsable_content?

      raise ArgumentError, "JSON API payload must contain the 'data' key" 
    end

    def process_relationship_datum(datum)
      {
        meta: {
          jsonapi_type: datum[:type],
          temp_id: datum[:'temp-id'],
          method: datum[:method]&.to_sym
        },
        attributes: datum[:id] ? { id: datum[:id] } : {},
        relationships: {}
      }
    end

    def meta_params
      data[:meta] || {}
    end

    def process_relationships(relationship_hash)
      {}.tap do |hash|
        relationship_hash.each_pair do |name, relationship_payload|
          name = name.to_sym
          data_payload = relationship_payload[:data]
          hash[name] = data_payload.nil? ? process_nil_relationship(name) : process_relationship(relationship_payload[:data])
        end
      end
    end

    def relationship?(name)
      relationships[name.to_sym].present?
    end

    # change empty relationship as `disassociate` hash so they will be removed
    def process_nil_relationship(name)
      attributes = {}
      method_name = :disassociate

      {
        meta: {
          jsonapi_type: name.to_sym,
          method: method_name
        },
        attributes: attributes,
        relationships: {}
      }
    end

    def meta(action: nil)
      results = super
      return results if action.present? || @env.nil?

      action = case @env['REQUEST_METHOD']
               when 'POST' then :create
               when 'PUT', 'PATCH' then :update
               when 'DELETE' then :destroy
               end

      results[:method] = action
      results
    end

    def path_map
      map = @params.select { |key, _| key =~ /_id$/ }.permit!.to_h
      map = filter_keys(map) { |key| key.gsub(/_id$/, '').to_sym }
      map = filter_keys(map) { |key| @parent_map[key] || key }
      map = filter_keys_presence(map) if @model < ActiveGraph::Node
      map
    end

    def filter_keys_presence(map)
      filter_keys(map) { |key| presence(key) || presence(key.to_s.pluralize.to_sym) }
    end

    def filter_keys(map)
      map.map { |key, v| [yield(key), v] }.select(&:first).to_h
    end

    def presence(key)
      key if @model.associations.include?(key)
    end

    def detect_conflict(key, path_value, body_value)
      raise Conflict.new(key, path_value, body_value) if path_value && body_value && body_value != path_value
    end

    private

    def parsable_content?
      true
    end

    def derive_resource_type(rel_name)
      if @model.include?(ActiveGraph::Node)
        @model.associations[rel_name].target_class.model_name.plural.to_s
      else
        # ApplicationRelationship resource doesn't have #associations or any other method to list all associations
        # "from_class" and "to_class" methods can contain value "any". Which makes it unreliable to use here
        # Using "rel_name.to_s.pluralize" as it works in most cases.
        # User can define a method on controller "" which will override this behaviour
        derive_resource_type_from_controller(rel_name) || rel_name.to_s.pluralize
      end
    end

    def derive_resource_type_from_controller(rel_name)
      controller_obj.derive_parent_resource_type(rel_name) if controller_obj.respond_to?(:derive_parent_resource_type)
    end

    def controller_obj
      @controller_obj ||= Graphiti.context[:object]
    end
  end
end
