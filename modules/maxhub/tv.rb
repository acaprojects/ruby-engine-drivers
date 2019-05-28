# encoding: ASCII-8BIT
# frozen_string_literal: true

module Maxhub; end

class Maxhub::Tv
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # Discovery Information
    tcp_port 8899
    descriptive_name 'Maxhub P75PC-G1 TV'
    generic_name :Display

    tokenize delimiter: "\xDD\xEE\xFF", indicator: "\xAA\xBB\xCC"

    def on_load
        on_update
        self[:volume_min] = 0
        self[:volume_max] = 100
    end

    def on_unload
    end

    def on_update
    end

    def connected
    end

    def disconnected
        schedule.clear
    end

    def power(state)
        target = is_affirmative?(state)
        self[:power_target] = target

        logger.debug { "Target = #{target} and self[:power] = #{self[:power]}" }
        if target == On && self[:power] != On
            send_cmd("01000001", name: :power_cmd, delay: 2000, timeout: 10000)
        elsif target == Off && self[:power] != Off
            send_cmd("01010002", name: :power_cmd, timeout: 10000)
        end
    end

    def power?
        send_cmd("01020003", name: :power_inq, priority: 0)
    end

    def volume(vol)
        val = in_range(vol, self[:volume_max], self[:volume_min])
        self[:volume_target] = val
        send_cmd("0300#{val.to_s(16).rjust(2, '0')}00", wait: false)
        volume?
    end

    def volume?
        send_cmd("03020005", name: :volume, priority: 0)
    end

    def mute_audio
        send_cmd("03010004", wait: false)
        mute?
    end

    def unmute_audio
        send_cmd("03010105", wait: false)
        mute?
    end

    def mute?
        send_cmd("03030006", name: :mute, priority: 0)
    end

    INPUTS_CMD = {
        :tv => "02010003",
        :av => "02020004",
        :vga3 => "020B000D",
        :vga1 => "02010003",
        :vga2 => "02040006",
        :hdmi1 => "02060008",
        :hdmi2 => "02070009",
        :hdmi3 => "02050007",
        :pc => "0208000A",
        :android => "020A000C",
        :hdmi4k => "020D000F",
        :whdi => "020C000E",
        :ypbpr => "020F0005",
        :androidslot => "020E0005"
    }

    INPUTS_INQ = {
        "81010082" => "tv",
        "81020083"=> "av",
        "81030084" => "vga1",
        "81040085" => "vga2",
        "81050086" => "hdmi3",
        "81060087" => "hdmi1",
        "81070088" => "hdmi2",
        "81080089" => "pc",
        "810A008B" => "android",
        "810D008E" => "hdmi4k",
        "810C008D" => "whdi",
        "810B008C" => "vga3"
    }

    def switch_to(input)
        self[:input_target] = input
        input = input.to_sym if input.class == String
        send_cmd(INPUTS_CMD[input], wait: false)
        input?
    end

    def input?
        send_cmd("02000002", name: :input, priority: 0)
    end

    def send_cmd(cmd, options = {})
        req = "AABBCC#{cmd}DDEEFF"
        logger.debug { "tell -- 0x#{req} -- #{options[:name]}" }
        options[:hex_string] = true
        send(req, options)
    end

    def received(data, deferrable, command)
        hex = byte_to_hex(data)
        return :success if command.nil? || command[:name].nil?
        return :ignore if (hex == "80000080" || hex == "80010081") && command[:name] != :power_cmd && command[:name] != :power_inq

        case command[:name]
        when :power_cmd
            if (self[:power_target] == On && hex == "80000080") || (self[:power_target] == Off && hex == "80010081")
                self[:power] = self[:power_target]
            else
                return :ignore
            end
        when :power_inq
            self[:power] = On if hex == "80000080"
            self[:power] = Off if hex == "80010081"
        when :input
            self[:input] = INPUTS_INQ[hex]
        when :volume
            self[:volume] = byte_to_hex(data[-2]).to_i(16)
        when :mute
            self[:mute] = On if hex == "82010083"
            self[:mute] = Off if hex == "82010184"
        end

        logger.debug { "Received 0x#{hex}\n" }
        return :success
    end
end
