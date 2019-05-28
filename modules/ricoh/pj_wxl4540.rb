# encoding: ASCII-8BIT
# frozen_string_literal: true

module Ricoh; end

class Ricoh::PJ_WXL4540
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # Discovery Information
    tcp_port 50915 # This port number is probably wrong
    descriptive_name 'Ricoh Projector Furud WXL4540'
    generic_name :Display

    # Communication settings
    tokenize indicator: '=', delimiter: "\x0D"

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
            send_cmd('PON', name: :power_cmd)
        elsif target == Off && self[:power] != Off
            send_cmd('POF', name: :power_cmd)
        end
    end

    def power?
        send_cmd('SPS', name: :power_inq)
    end

    INPUTS = {
        vga: '3',
        vga2: '5',
        hdmi: '6',
        hdmi2: '7',
        video: '9'
    }
    INPUTS.merge!(INPUTS.invert)
    def switch_to(input)
        input = input.to_sym if input.class == String
        send_cmd("INP:#{INPUTS[input]}", name: :input_cmd)
    end

    def input?
        send_cmd('SIS', name: :input_inq)
    end

    ERRORS = {
        '0' => 'No Error',
        '1' => 'Light source Error',
        '4' => 'Fan Speed Error',
        '8' => 'Temperature Error',
        '16' => 'Color Wheel (Phospher wheel)'
    }.freeze
    def error?
        send_cmd('SER', name: :error_inq)
    end

    def mute(state)
        target = is_affirmative?(state)

        # Execute command
        logger.debug { "Target = #{target} and self[:mute] = #{self[:mute]}" }
        if target == On && self[:mute] != On
            send_cmd('MUT:1', name: :mute_cmd)
        elsif target == Off && self[:mute] != Off
            send_cmd('MUT:0', name: :mute_cmd)
        end
    end

    PRESETS = {
        bright: '0',
        pc: '1',
        movie: '2',
        game: '3',
        user: '4'
    }
    PRESETS.merge!(PRESETS.invert)
    def preset(mode)
        mode = mode.to_sym if mode.class == String
        send_cmd("PIC:#{PRESETS[mode]}", name: :preset_cmd)
    end

    def send_cmd(cmd, options = {})
        req = "##{cmd}\r"
        logger.debug("tell -- #{cmd} -- #{options[:name]}")
        send(req, options)
    end

    def received(data, deferrable, command)
        logger.debug("Received #{data}\n")
        value = data[/[^:]+$/]
        case command[:name]
        when :power_cmd
            # assuming that it replies with SC#{id} where id = 0
            # unsure if this is correct
            self[:power] = self[:power_target] if value == 'SC0'
        when :power_inq
            self[:power] = value == '0' ? Off : On
        when :input_cmd
            self[:input] = INPUTS[value]
        when :input_inq
            self[:input] = INPUTS[value]
        when :preset_cmd
            self[:preset] = PRESETS[value]
        when :mute_cmd
            self[:mute] = value == '1'
        when :mute_inq
            self[:mute] = value == '1'
        when :error_inq
            self[:error] = ERRORS[value]
        end
        :success
    end
end
