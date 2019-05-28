module Shure; end
module Shure::Mixer; end

# Documentation: http://www.shure.pl/dms/shure/products/mixer/user_guides/shure_intellimix_p300_command_strings/shure_intellimix_p300_command_strings.pdf

class Shure::Mixer::P300
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # Discovery Information
    tcp_port 2202
    descriptive_name 'Shure P300 IntelliMix Audio Conferencing Processor'
    generic_name :Mixer

    tokenize indicator: "< REP ", delimiter: " >"

    def on_load
        on_update

        self[:output_gain_max] = 1400
        self[:output_gain_min] = 0
    end

    def on_update
    end

    def connected
    end

    def disconnected
        schedule.clear
    end

    def do_poll
    end

    def reboot
        send_cmd("REBOOT", name: :reboot)
    end

    def preset(number)
        send_cmd("PRESET #{number}", name: :present_cmd)
    end
    alias_method :trigger, :preset

    def preset?
        send_inq("PRESET", name: :preset_inq, priority: 0)
    end
    alias_method :trigger?, :preset?

    def flash_leds
        send_cmd("FLASH ON", name: :flash_cmd)
    end

    def gain(group, value)
        val = in_range(value, self[:output_gain_max], self[:output_gain_min])

        faders = group.is_a?(Array) ? group : [group]

        faders.each do |fad|
            send_cmd("#{fad.to_s.rjust(2, '0')} AUDIO_GAIN_HI_RES #{val.to_s.rjust(4, '0')}", group_type: :fader_cmd, wait: true)
        end
    end
    alias_method :fader, :gain

    def gain?(group)
        faders = group.is_a?(Array) ? group : [group]

        faders.each do |fad|
            send_inq("#{fad.to_s.rjust(2, '0')} AUDIO_GAIN_HI_RES", group_type: :fader_inq, wait: true, priority: 0)
        end
    end
    alias_method :fader?, :gain?

    def mute(group, value = true)
        state = is_affirmative?(value) ? "ON" : "OFF"

        faders = group.is_a?(Array) ? group : [group]

        faders.each do |fad|
            send_cmd("#{fad.to_s.rjust(2, '0')} AUDIO_MUTE #{state}", group_type: :mute_cmd, wait: true)
        end
    end

    def unmute(group)
        mute(group, false)
    end

    def mute?(group)
        faders = group.is_a?(Array) ? group : [group]

        faders.each do |fad|
            send_inq("#{fad.to_s.rjust(2, '0')} AUDIO_MUTE", group_type: :mute_inq, wait: true, priority: 0)
        end
    end

    # not sure what the difference between this mute is
    def mute_all(value = true)
        state = is_affirmative?(value) ? "ON" : "OFF"

        send_cmd("DEVICE_AUDIO_MUTE #{state}", name: :mute)
    end

    def unmute_all
        mute_all(false)
    end

    def error?
        send_inq("LAST_ERROR_EVENT", name: :error)
    end

    def send_inq(cmd, options = {})
        req = "< GET #{cmd} >"
        logger.debug { "Sending: #{req}" }
        send(req, options)
    end

    def send_cmd(cmd, options = {})
        req = "< SET #{cmd} >"
        logger.debug { "Sending: #{req}" }
        send(req, options)
    end

    def received(data, deferrable, command)
        logger.debug { "Received: #{data}" }

        # Exit function early if command is nil or
        # if command is not nil and both name and group_type are nil
        return :success if command.nil? || (command[:name].nil? && command[:group_type].nil?)

        data = data.split

        if command[:name] != :error
            cmd = data[-2].to_sym
        else
            cmd = :LAST_ERROR_EVENT
        end

        case cmd
        when :PRESET
            self[:preset] = data[-1].to_i
        when :DEVICE_AUDIO_MUTE
            self[:mute] = data[-1] == "ON"
        when :AUDIO_MUTE
            self["channel#{data[0].to_i}_mute"] = data[-1] == "ON"
        when :AUDIO_GAIN_HI_RES
            self["channel#{data[0].to_i}_gain"] = data[-1].to_i
        when :LAST_ERROR_EVENT
            error = data[1..-1].join(" ")
            self[:error] = error
        end
        return :success
    end
end
