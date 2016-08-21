module Knx; end

require 'knx/object_server'

class Knx::BaosLighting
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 12004
    descriptive_name 'KNX BAOS Lighting'
    generic_name :Lighting

    # Communication settings
    delay between_sends: 40
    wait_response false

    tokenize indicator: "\x06", callback: :check_length


    def on_load
        @os = KNX::ObjectServer.new

        on_update
    end

=begin
Settings:

    "triggers": {
        "area_1": [
            [161, true, "0: all on"], [161, false, "1: all off"]
        ]
    }
=end
    def on_update
        @triggers    = setting(:triggers) || {}
        @area_lookup = {}

        @triggers.each do |key, area|
            number = key.to_s.split('_')[1].to_i

            area.each do |trigger|
                @area_lookup[trigger[0]] = number
            end
        end
    end

    def connected
        req = @os.status(1).to_binary_s
        send req, priority: 0

        @polling_timer = schedule.every('50s') do
            logger.debug { "Maintaining connection" }
            send req, priority: 0
        end
    end

    def disconnected
        #
        # Disconnected may be called without calling connected
        #    Hence the check if timer is nil here
        #
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end


    # ==================================
    # Module Compatibility methods
    # ==================================
    def trigger(area, number, fade = 1000)
        index, value = @triggers[:"area_#{area}"][number]
        send_request index, value
    end
    # ==================================



    def send_request(index, value)
        logger.debug { "Requesting #{index} = #{value}" }
        req = @os.action(index, value).to_binary_s
        send req
    end

    def send_query(num)
        logger.debug { "Requesting value of #{index}" }
        req = @os.status(num).to_binary_s
        send req, wait: true
    end

    def received(data, resolve, command)
        result = @os.read("\x06#{data}")

        if result.error == :no_error
            logger.debug {
                if result.data && result.data.length > 0
                    "Index: #{result.header.start_item}, Item Count: #{result.header.item_count}, Start value: #{result.data[0].value.bytes}"
                else
                    "Received #{result}"
                end
            }

            # Check if this item is in a lighting area
            result.data.each do |item|
                value_id = item.id
                area = @area_lookup[value_id]

                # If this is in a lighting area then we need to find which index
                # There might be multiple index's using the same trigger ID with
                # a different value
                if area
                    updated = false

                    @triggers[:"area_#{area}"].each_with_index do |trigger, index|
                        if value_id == trigger[0]
                            # We need to coerce the value
                            if [true, false].include?(trigger[1])
                                if trigger[1] == (item.value.bytes[0] == 1)
                                    updated = true
                                    self["trigger_group_#{area}"] = index
                                    break
                                end
                            else
                                if trigger[1] == item.value.bytes[0]
                                    updated = true
                                    self["trigger_group_#{area}"] = index
                                    break
                                end
                            end
                        end
                    end

                    if not updated
                        logger.warn "Unknown value #{item.value.bytes} for known index #{value_id} in area #{area}"
                    end
                else
                    self["index_#{value_id}"] = item.value.bytes[0]
                end
            end
        else
            logger.warn "Error response: #{result.error} (#{result.error_code})"
        end
    end


    protected


    def check_length(byte_str)
        if byte_str.length > 5
            header = KNX::Header.new

            # indicator is removed by the tokenizer
            byte_str = "\x06#{byte_str}"
            header.read(byte_str)

            if byte_str.length >= header.request_length
                return header.request_length
            end
        end
        false
    end
end

