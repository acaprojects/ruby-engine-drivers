# encoding: ASCII-8BIT
# frozen_string_literal: true

module Ricoh; end

class Ricoh::D6500
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # Discovery Information
    tcp_port 50915 # This port number is probably wrong
    descriptive_name 'Ricoh D6500 Interactive Whiteboard'
    generic_name :Display

    # Communication settings
    tokenize delimiter: "\x0D"

    default_settings(
        id: '02'
    )

    def on_load
        self[:volume_min] = 0
        self[:volume_max] = 100
        on_update
    end

    def on_update
        self[:id] = setting(:id)
    end

    def on_unload; end

    def connected; end

    def disconnected
        # Disconnected will be called before connect if initial connect fails
        schedule.clear
    end

    def power(state)
        target = is_affirmative?(state)
        self[:power_target] = target

        # Execute command
        logger.debug { "Target = #{target} and self[:power] = #{self[:power]}" }
        if target == On && self[:power] != On
            send_cmd("#{COMMANDS[:power_cmd]}#{prepend('001')}", name: :power_cmd)
        elsif target == Off && self[:power] != Off
            send_cmd("#{COMMANDS[:power_cmd]}#{prepend('000')}", name: :power_cmd)
        end
    end

    def power?
        send_inq(COMMANDS[:power_inq], name: :power_inq)
    end

    INPUTS = {
        vga: '000',
        hdmi: '001',
        hdmi2: '002',
        av: '003',
        ypbpr: '004',
        svideo: '005',
        dvi: '006',
        display_port: '007',
        sdi: '008',
        multimedia: '009',
        network: '010',
        usb: '011'
    }
    INPUTS.merge!(INPUTS.invert)
    def switch_to(input)
        input = input.to_sym if input.class == String
        self[:input_target] = input
        send_cmd("#{COMMANDS[:input_cmd]}#{prepend(INPUTS[input])}", name: :input_cmd)
    end

    def input?
        send_inq(COMMANDS[:input_inq], name: :input_inq)
    end

    AUDIO_INPUTS = {
        audio: '000',
        audio2: '001',
        hdmi: '002',
        hdmi2: '003',
        display_port: '004',
        sdi: '005',
        multimedia: '006'
    }.freeze
    def switch_audio(input)
        input = input.to_sym if input.class == String
        self[:audio_target] = input
        send_cmd("#{COMMANDS[:audio_cmd]}#{prepend(AUDIO_INPUTS[input])}", name: :audio_cmd)
    end

    def audio?
        send_inq(COMMANDS[:audio_inq], name: :audio_inq)
    end

    def volume(vol)
        val = in_range(vol, self[:volume_max], self[:volume_min])
        self[:volume_target] = val
        val = val.to_s.rjust(3, '0')
        logger.debug("volume = #{prepend(val)}")
        send_cmd("#{COMMANDS[:volume_cmd]}#{prepend(val)}", name: :volume_cmd)
    end

    def volume?
        send_inq(COMMANDS[:volume_inq], name: :volume_inq)
    end

    def mute(state)
        target = is_affirmative?(state)
        self[:mute_target] = target

        # Execute command
        logger.debug { "Target = #{target} and self[:mute] = #{self[:mute]}" }
        if target == On && self[:mute] != On
            send_cmd("#{COMMANDS[:mute_cmd]}#{prepend('001')}", name: :mute_cmd)
        elsif target == Off && self[:mute] != Off
            send_cmd("#{COMMANDS[:mute_cmd]}#{prepend('000')}", name: :mute_cmd)
        end
    end

    def mute?
        send_inq(COMMANDS[:mute_inq], name: :mute_inq)
    end

    COMMANDS = {
        power_cmd: '21',
        input_cmd: '22',
        volume_cmd: '35',
        mute_cmd: '36',
        audio_cmd: '88',
        power_inq: '6C',
        input_inq: '6A',
        volume_inq: '66',
        mute_inq: '67',
        audio_inq: '88'
    }.freeze
    def send_cmd(cmd, options = {})
        req = "3#{self[:id][0]}3#{self[:id][1]}73#{cmd}0D"
        req = "3#{req.length / 2}#{req}"
        logger.debug("tell -- 0x#{req} -- #{options[:name]}")
        options[:hex_string] = true
        send(req, options)
    end

    def send_inq(inq, options = {})
        req = "3#{self[:id][0]}3#{self[:id][1]}67#{inq}#{prepend('000')}0D"
        req = "3#{req.length / 2}#{req}"
        logger.debug("ask -- 0x#{req} -- #{options[:name]}")
        options[:hex_string] = true
        send(req, options)
    end

    def received(data, deferrable, command)
        hex = byte_to_hex(data).upcase
        logger.debug("Received 0x#{hex}\n")
        if hex[-2..-1] == '2B' # this means the sent command was valid
            cmd = command[:name].to_s[/[a-z]+/]
            self[cmd] = self[cmd + '_target']
        else
            value = hex[-5] + hex[-3] + hex[-1]
            case command[:name]
            when :power_inq
                self[:power] = value == '001' ? On : Off
            when :input_inq
                self[:input] = INPUTS[value]
            when :audio_inq
                self[:audio] = AUDIO_INPUTS[value]
            when :volume_inq
                self[:volume] = value.to_i
            when :mute_inq
                self[:mute] = value == '001' ? On : Off
            end
        end
        :success
    end

    def prepend(str)
        str = str.to_s if str.class != String
        joined = ''
        str.each_char do |c|
            joined += "3#{c}"
        end
        joined
    end
end
