# frozen_string_literal: true

require 'json'

module Cisco; end
module Cisco::Spark; end
module Cisco::Spark::Xapi; end

module Cisco::Spark::Xapi::Response
    class ParserError < StandardError; end

    module_function

    # Parse a raw device response.
    #
    # @param data [String] the raw device response to parse
    # @param into [Class] the object class to parser into (subclass of Hash)
    # @return a nested structure containing the fully parsed response
    # @raise [ParserError] if data is invalid
    def parse(data, into: Hash)
        response = JSON.parse data, object_class: into
        compress response
    rescue JSON::ParserError => error
        raise ParserError, error
    end

    # Lift the 'Value' keys returned from raw response so their parent contains
    # a direct value object rather than a hash of the value and type.
    def compress(fragment)
        case fragment
        when Hash
            value, valuespaceref = fragment.values_at(:value, :valuespaceref)
            if value&.is_a? String
                valuespace = valuespaceref&.split('/')&.last&.to_sym
                convert value, valuespace
            else
                fragment.transform_values { |item| compress item }
            end
        when Array
            fragment.map { |item| compress item }
        else
            fragment
        end
    end

    BOOLEAN ||= ->(val) { truthy? val }
    BOOL_OR ||= lambda do |term|
        sym = term.to_sym
        ->(val) { val == term ? sym : BOOLEAN[val] }
    end

    PARSERS ||= {
        TTPAR_OnOff: BOOLEAN,
        TTPAR_OnOffAuto: BOOL_OR['Auto'],
        TTPAR_OnOffCurrent: BOOL_OR['Current'],
        TTPAR_MuteEnabled: BOOLEAN
    }.freeze

    # Map a raw response value to an appropriate datatype.
    #
    # @param value [String] the value to convert
    # @param valuespace [Symbol] the Cisco value space reference
    # @return the value as an appropriate core datatype
    def convert(value, valuespace)
        parser = PARSERS[valuespace]
        if parser
            parser.call(value)
        else
            begin
                Integer(value)
            rescue ArgumentError
                if truthy? value
                    true
                elsif falsey? value
                    false
                elsif value =~ /\A[[:alpha:]]+\z/
                    value.to_sym
                else
                    value
                end
            end
        end
    end

    def truthy?(value)
        ::Orchestrator::Constants::On_vars.include? value
    end

    def falsey?(value)
        ::Orchestrator::Constants::Off_vars.include? value
    end
end
