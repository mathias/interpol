require 'json-schema'
require 'interpol/errors'

module JSON
  # The JSON-schema namespace
  class Schema
    # Monkey patch json-schema to reject unrecognized types.
    # It allows them because the spec says they should be allowed,
    # but we don't want to allow them.
    # For more info, see:
    # - https://github.com/hoxworth/json-schema/pull/37
    # - https://github.com/hoxworth/json-schema/pull/38
    class TypeAttribute
      (class << self; self; end).class_eval do
        alias original_data_valid_for_type? data_valid_for_type?
        def data_valid_for_type?(data, type)
          return false unless TYPE_CLASS_MAPPINGS.has_key?(type)
          original_data_valid_for_type?(data, type)
        end
      end
    end
  end
end

module Interpol
  module HashFetcher
    # Unfortunately, on JRuby 1.9, the error raised from Hash#fetch when
    # the key is not found does not include the key itself :(. So we work
    # around it here.
    def fetch_from(hash, key)
      hash.fetch(key) do
        raise ArgumentError.new("key not found: #{key.inspect}")
      end
    end
  end

  # Represents an endpoint. Instances of this class are constructed
  # based on the endpoint definitions in the YAML files.
  class Endpoint
    include HashFetcher
    attr_reader :name, :route, :method

    def initialize(endpoint_hash)
      @name        = fetch_from(endpoint_hash, 'name')
      @route       = fetch_from(endpoint_hash, 'route')
      @method      = fetch_from(endpoint_hash, 'method').downcase.to_sym
      @definitions = extract_definitions_from(endpoint_hash)
      validate_name!
    end

    def find_definition!(version, message_type)
      @definitions.fetch([message_type, version]) do
        message = "No definition found for #{name} endpoint for version #{version}"
        message << " and message_type #{message_type}"
        raise ArgumentError.new(message)
      end
    end

    def find_example_for!(version, message_type)
      find_definition!(version, message_type).first.examples.first
    end

    def find_example_status_code_for!(version)
      find_definition!(version, 'response').first.example_status_code
    end

    def available_versions
      definitions.map { |d| d.first.version }
    end

    def definitions
      # sort all requests before all responses
      # sort higher version numbers before lower version numbers
      @definitions.values.sort do |x,y|
        if x.first.message_type == y.first.message_type
          y.first.version <=> x.first.version
        else
          x.first.message_type <=> y.first.message_type
        end
      end
    end

    def route_matches?(path)
      path =~ route_regex
    end

  private

    def route_regex
      @route_regex ||= begin
        regex_string = route.split('/').map do |path_part|
          if path_part.start_with?(':')
            '[^\/]+' # it's a parameter; match anything
          else
            Regexp.escape(path_part)
          end
        end.join('\/')

        /\A#{regex_string}\z/
      end
    end

    DEFAULT_MESSAGE_TYPE = 'response'

    def extract_definitions_from(endpoint_hash)
      definitions = Hash.new { |h, k| h[k] = [] }

      fetch_from(endpoint_hash, 'definitions').each do |definition|
        fetch_from(definition, 'versions').each do |version|
          message_type = definition.fetch('message_type', DEFAULT_MESSAGE_TYPE)
          key = [message_type, version]
          definitions[key] << EndpointDefinition.new(name, version, message_type, definition)
        end
      end

      definitions
    end

    def validate_name!
      unless name =~ /\A[\w\-]+\z/
        raise ArgumentError, "Invalid endpoint name (#{name.inspect}). "+
                             "Only letters, numbers, underscores and dashes are allowed."
      end
    end
  end

  # Wraps a single versioned definition for an endpoint.
  # Provides the means to validate data against that version of the schema.
  class EndpointDefinition
    include HashFetcher
    attr_reader :endpoint_name, :message_type, :version, :schema, :path_params, :query_params, :examples

    def initialize(endpoint_name, version, message_type, definition)
      @endpoint_name  = endpoint_name
      @message_type   = message_type
      @status_codes   = StatusCodeMatcher.new(definition['status_codes'])
      @version        = version
      @schema         = fetch_from(definition, 'schema')
      @path_params    = definition.fetch('path_params', {})
      @query_params   = definition.fetch('query_params', {})
      @examples       = fetch_from(definition, 'examples').map { |e| EndpointExample.new(e, self) }
      make_schema_strict!(@schema)
    end

    def validate_data!(data)
      errors = ::JSON::Validator.fully_validate_schema(schema)
      raise ValidationError.new(errors, nil, description) if errors.any?
      errors = ::JSON::Validator.fully_validate(schema, data)
      raise ValidationError.new(errors, data, description) if errors.any?
    end

    def description
      "#{endpoint_name} (v. #{version}, mt. #{message_type}, sc. #{status_codes})"
    end

    def status_codes
      @status_codes.code_strings.join(',')
    end

    def matches_status_code?(status_code)
      status_code.nil? || @status_codes.matches?(status_code)
    end

    def example_status_code
      @example_status_code ||= @status_codes.example_status_code
    end

  private

    def make_schema_strict!(raw_schema, modify_object=true)
      return unless Hash === raw_schema

      raw_schema.each do |key, value|
        make_schema_strict!(value, key != 'properties')
      end

      return unless modify_object

      raw_schema['additionalProperties'] ||= false
      raw_schema['required'] = !raw_schema.delete('optional')
    end
  end

  # Holds the acceptable status codes for an enpoint entry
  # Acceptable status code are either exact status codes (200, 404, etc)
  # or partial status codes (2xx, 3xx, 4xx, etc). Currently, partial status
  # codes can only be a digit followed by two lower-case x's.
  class StatusCodeMatcher
    attr_reader :code_strings

    def initialize(codes)
      codes = ["xxx"] if Array(codes).empty?
      @code_strings = codes
      validate!
    end

    def matches?(status_code)
      code_regexes.any? { |re| re =~ status_code.to_s }
    end

    def example_status_code
      example_status_code = "200"
      code_strings.first.chars.each_with_index do |char, index|
        example_status_code[index] = char if char != 'x'
      end
      example_status_code
    end

    private
      def code_regexes
        @code_regexes ||= code_strings.map do |string|
          /\A#{string.gsub('x', '\d')}\z/
        end
      end

      def validate!
        code_strings.each do |code|
          # ensure code is 3 characters and all chars are a number or 'x'
          # http://rubular.com/r/4sl68Bb4XO
          unless code =~ /\A[\dx]{3}\Z/
            raise StatusCodeMatcherArgumentError, "#{code} is not a valid format"
          end
        end
      end
  end

  # Wraps an example for a particular endpoint entry.
  class EndpointExample
    attr_reader :data, :definition

    def initialize(data, definition)
      @data, @definition = data, definition
    end

    def validate!
      definition.validate_data!(data)
    end
  end
end
