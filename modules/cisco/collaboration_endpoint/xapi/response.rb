# frozen_string_literal: true

require 'json'

module Cisco; end
module Cisco::CollaborationEndpoint; end
module Cisco::CollaborationEndpoint::Xapi; end

module Cisco::CollaborationEndpoint::Xapi::Response
    class ParserError < StandardError; end

    module_function

    # Parse a raw device response.
    #
    # @param data [String] the raw device response to parse
    # @return a nested structure containing the fully parsed response
    # @raise [ParserError] if data is invalid
    def parse(data)
        response = JSON.parse data, symbolize_names: true
        compress response
    rescue JSON::ParserError => error
        raise ParserError, error
    end

    # Lift the 'Value' keys returned from raw response so their parent contains
    # a direct value object rather than a hash of the value and type.
    def compress(fragment)
        case fragment
        when Hash
            value, valuespaceref = fragment.values_at(:Value, :valueSpaceRef)
            if value&.is_a? String
                valuespace = valuespaceref&.split('/')&.last&.to_sym
                convert value, valuespace
            else
                fragment.transform_values { |item| compress item }
            end
        when Array
            fragment.each_with_object({}) do |item, h|
                id = item.delete(:id)
                id = id.is_a?(String) && id[/^\d+$/]&.to_i || id
                h[id] = compress item
            end
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
    def convert(value, valuespace = nil)
        parser = PARSERS[valuespace]
        if parser
            parser.call(value)
        else
            begin
                Integer(value)
            rescue
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
        (::Orchestrator::Constants::On_vars + [
            'Standby', # ensure standby state is properly mapped
            'Available'
        ]).include? value
    end

    def falsey?(value)
        (::Orchestrator::Constants::Off_vars + [
            'Unavailable'
        ]).include? value
    end
end
