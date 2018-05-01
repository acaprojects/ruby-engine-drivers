# encoding: ASCII-8BIT
# frozen_string_literal: true

module X3m; end
module X3m::Displays; end

# Protocol: https://aca.im/driver_docs/X3M/RS-232+Instructions.pdf

class X3m::Displays::WallDisplay
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    tcp_port 4999  # control assumed via Global Cache
    descriptive_name '3M Wall Display'
    generic_name :Display

    description <<-DESC
        Display control is via RS-232 only. Ensure IP -> RS-232 converter has
        been configured to provide comms at 9600,N,8,1.
    DESC

    tokenize delimiter: "\r"

    def on_load
        on_update

        # Meta data for inquiring interfaces
        self[:type] = :lcd
        self[:power_target] = setting(:power_target)

        # The device API not does provide any idempotent method to query state
        # so mark everything as an unknown until we know otherwise.
        Protocol::COMMAND
            .keys
            .select { |entry| entry.is_a? Symbol }
            .each do |state|
                self[state] = :unknown
            end
    end

    def on_unload
    end

    def on_update
        self[:monitor_id] = setting(:monitor_id) || :all
        self[:volume_min] = setting(:volume_min) || 0
        self[:volume_max] = setting(:volume_max) || 100
    end

    def connected
        schedule.every('15s') { do_poll }
    end

    def disconnected
        schedule.clear
    end

    def do_poll
        logger.debug 'Polling device for connectivity heartbeat'

        # The device does not provide any query only methods for interaction.
        # Re-apply the current known power state to provide a comms heartbeat
        # if we can do it safely.
        power(self[:power_target], priority: 0) unless self[:power_target].nil?
    end

    def power(state, **options)
        state = is_affirmative? state
        if state != self[:power_target]
            # Define setting for polling
            self[:power_target] = state
            define_setting(:power_target, state)
        end
        set :power, state, options
    end

    def switch_to(input)
        input = input.to_sym
        set :input, input
    end

    def mute_audio(state = true)
        state = is_affirmative? state
        set :audio_mute, state
    end

    def unmute_audio
        mute_audio false
    end

    def volume(level)
        level = in_range level, 100
        set :volume, level
    end

    def brightness(value)
        value = in_range value, 100
        set :brightness, value
    end

    def contrast(value)
        value = in_range value, 100
        set :contrast, value
    end

    def sharpness(value)
        value = in_range value, 100
        set :sharpness, value
    end

    def colour_temp(value)
        value = value.to_sym
        set :colour_temp, value
    end

    protected

    def set(command, param, **opts, &block)
        logger.debug { "Setting #{command} -> #{param}" }

        op_code, value = Protocol.lookup command, param

        packet = Protocol.build_packet op_code, value, self[:monitor_id]

        opts[:emit] = block if block_given?
        opts[:name] ||= command

        send packet, opts
    end

    def received(data, resolve, command)
        begin
            # Re-append the delimiter that the tokenizer splits on to allow the
            # parser to deal with complete packets.
            data << "\r"
            response = Protocol.parse_response data
        rescue StandardError => parse_error
            logger.warn parse_error.message
            return :fail
        end

        unless response[:success]
            logger.warn { "Device error: #{response.inspect}" }
            return :abort
        end

        logger.debug { "Device response received: #{response.inspect}" }

        state, value = response.values_at :command, :value

        self[state] = value

        :success
    end
end

module X3m::Displays::WallDisplay::Util
    module_function

    # Convert an integral value to a byte array, with each element containing
    # the ASCII character code that represents the original value at that
    # offset (big-endian).
    #
    # encode(10, length: 2)
    #  => [48, 65]
    def encode(value, length:)
        value
            .to_s(16)
            .upcase
            .rjust(length, '0')
            .bytes
    end

    # Decode a section of an rx packet back to a usable value.
    def decode(value)
        value.length > 1 ? value.hex : value.ord
    end

    # Scale a value previous on a 0..old_max scale to it's equivalent within
    # 0..new_max
    def scale(value, old_max, new_max)
        (new_max * value) / old_max
    end

    # Expand a hashmap to provide inverted k/v pairs for bi-directional lookup
    def bidirectional(hash)
        hash
            .merge(hash.invert)
            .freeze
    end

    # Recursive dig into nested hash maps (pointfree version of Hash#dig
    # availble in Ruby 2.3+).
    def dig(hash, key, *keys)
        value = hash[key]
        if value.nil? || keys.empty?
            value
        else
            dig value, *keys
        end
    end
end

module X3m::Displays::WallDisplay::Protocol
    module_function

    Util = ::X3m::Displays::WallDisplay::Util

    MARKER = {
        SOH: 0x01,
        STX: 0x02,
        ETX: 0x03,
        delimiter: 0x0d,
        reserved: 0x30
    }.freeze

    MONITOR_ID = Util.bidirectional({
        all: 0x2a
    }.merge(
        Hash[(1..9).zip(0x41..0x49)]
    ))

    MESSAGE_SENDER = Util.bidirectional({
        pc: 0x30
    })

    MESSAGE_TYPE = Util.bidirectional({
        set_parameter_command: 0x45,
        set_parameter_reply: 0x46
    })

    COMMAND = Util.bidirectional({
        brightness: 0x0110,
        contrast: 0x0112,
        sharpness: 0x018c,
        colour_temp: 0x0254,
        volume: 0x0062,
        audio_mute: 0x008d,
        input: 0x02cb,
        aspect_ratio: 0x02df,
        power: 0x0003
    })

    # Definitions for non-numeric command arguments
    PARAMS = {
        colour_temp: {
            _9300K: 0,
            _6500K: 1,
            user: 2
        },
        audio_mute: {
            false => 0,
            true => 1
        },
        input: {
            vga: 0,
            dvi: 1,
            hdmi: 2,
            dp: 3
        },
        aspect_ratio: {
            full: 0,
            _16_10: 1,
            _4_3: 2
        },
        power: {
            false => 0,
            true => 1
        }
    }
    PARAMS.transform_values! { |param| Util.bidirectional(param) }
    PARAMS.freeze

    # Map a symbolic command and parameter value to an [op_code, value]
    def lookup(command, param)
        op_code = COMMAND[command]

        # Volume is the only numeric value that's not 0-100. Normalise to match.
        value = if command == :volume
                    Util.scale param, 100, 30
                else
                    Util.dig(PARAMS, command, param) || param
                end

        [op_code, value]
    end

    # Resolve an op_code and value back to a [command, param]
    # (inverse of lookup)
    def resolve(op_code, value)
        command = COMMAND[op_code]

        # As above, normalise volume to match the same range as other
        # parameters.
        param = if command == :volume
                    Util.scale value, 30, 100
                else
                    mapped_value = Util.dig(PARAMS, command, value)
                    mapped_value.nil? ? value : mapped_value
                end

        [command, param]
    end

    # Build a 'set_parameter_command' packet ready for transmission to the
    # device(s).
    def build_packet(op_code, value, monitor_id = :all)
        message = [
            MARKER[:STX],
            *Util.encode(op_code, length: 4),
            *Util.encode(value, length: 4),
            MARKER[:ETX]
        ]

        header = [
            MARKER[:SOH],
            MARKER[:reserved],
            MONITOR_ID[monitor_id],
            MESSAGE_SENDER[:pc],
            MESSAGE_TYPE[:set_parameter_command],
            *Util.encode(message.length, length: 2)
        ]

        # XOR of byte 1 -> end of message payload for checksum
        bcc = (header.drop(1) + message).reduce(:^)

        header + message << bcc << MARKER[:delimiter]
    end

    # Parse a response packet to a hash of its decoded components.
    def parse_response(packet)
        if @rx_structure.nil?
            capture = ->(name, len = 1) { "(?<#{name}>.{#{len}})" }
            marker = ->(key) { '\x' + MARKER[key].to_s(16).rjust(2, '0') }

            @rx_structure = %r{
                #{marker[:SOH]}
                #{marker[:reserved]}
                #{capture['receiver']}
                #{capture['monitor_id']}
                #{capture['message_type']}
                #{capture['message_len', 2]}
                #{marker[:STX]}
                #{capture['result_code', 2]}
                #{capture['op_code', 4]}
                #{capture['op_code_type', 2]}
                #{capture['max_value', 4]}
                #{capture['value', 4]}
                #{marker[:ETX]}
                #{capture['bcc']}
                #{marker[:delimiter]}
            }x
        end

        rx = packet.match @rx_structure
        if rx.nil?
            raise 'invalid packet structure'
        end

        bcc = packet.bytes[1..-3].reduce(:^)
        if bcc != rx[:bcc].ord
            raise 'invalid checksum'
        end

        rx_data = Hash[rx.names.zip rx.captures]
        rx_data.transform_values! { |val| Util.decode val }

        command, param = resolve rx_data['op_code'], rx_data['value']

        {
            receiver: MESSAGE_SENDER[rx_data.fetch 'receiver'],
            monitor_id: MONITOR_ID[rx_data.fetch 'monitor_id'],
            message_type: MESSAGE_TYPE[rx_data.fetch 'message_type'],
            success: rx_data.fetch('result_code') == 0,
            command: command,
            value: param
        }
    end
end
