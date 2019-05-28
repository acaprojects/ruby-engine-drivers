# frozen_string_literal: true
# encoding: ASCII-8BIT
module Pjlink; end

# Documentation: https://pjlink.jbmia.or.jp/english/data_cl2/PJLink_5-1.pdf

class Pjlink::Pjlink
    include ::Orchestrator::Constants

    # Discovery Information
    tcp_port 4352
    descriptive_name 'Projector with Pjlink control'
    generic_name :Display

    # Communication settings
    # 24bytes with header however we'll ignore the footer
    tokenize indicator: "%1", delimiter: "\x0D"

    def on_load
    end

    def on_update
      self[:power_target_enabled] = setting(:power_target_enabled) || true
    end

    def connected
        poll
        schedule.every('10s') { poll }
    end

    def disconnected
        # Stop polling
        schedule.clear
    end

    INPUTS = {
        hdmi: '31',
        hdmi2: '32',
        hdmi3: '33',
        vga: '11',
        vga2: '12',
        vga3: '13',
        usb: '41',
        network: '51'
    }
    LOOKUP_INPUTS = INPUTS.invert

    def switch_to(input)
        logger.debug { "requesting to switch to: #{input}" }
        self[:input_target]     = input.to_sym
        do_send(COMMANDS[:input], INPUTS[input.to_sym], name: :input)
        input?
    end

    def power(state = true, _ = nil)
        self[:power_target] = state if self[:power_target_enabled]
        do_send(COMMANDS[:power], state ? '1' : '0', retries: 10, name: :power)
    end

    def mute(state = true)
        do_send(COMMANDS[:mute], state ? '31' : '30', name: :mute)
    end
    def unmute
        mute false
    end

    def video_mute(state = true)
        do_send(COMMANDS[:mute], state ? '11' : '10', name: :video_mute)
    end
    def video_unmute
        mute false
    end

    def audio_mute(state = true)
        do_send(COMMANDS[:mute], state ? '21' : '20', name: :audio_mute)
    end
    def audio_unmute
        mute false
    end

    def poll
      power?.finally do
        if self[:power] then
          input?
          mute?
          lamp?
          error_status?
        end
        power(self[:power_target]) if self[:power_target_enabled] && !self[:power_target].nil? && (self[:power] != self[:power_target])
        switch_to(self[:input_target]) if self[:input_target] && (self[:input] != self[:input_target])
      end
    end

    COMMANDS = {
      power: 'POWR',
      mute: 'AVMT',
      input: 'INPT',
      error_status: 'ERST',
      lamp: 'LAMP',
      name: 'NAME1'
    }
    LOOKUP_COMMANDS = COMMANDS.invert

    COMMANDS.each do |name, pj_cmd|
      define_method :"#{name}?" do
        do_query pj_cmd
      end
    end

    protected

    def do_query(command, **options)
        cmd = "%1#{command} ?\x0D"
        logger.debug "sending query to projector: #{cmd}"
        send(cmd, options)
    end

    def do_send(command, parameter, **options)
        cmd = "%1#{command} #{parameter}\x0D"
        logger.debug "sending command to projector: #{cmd}"
        send(cmd, options)
    end

    def received(data, resolve, command)
        logger.debug { "sent: #{data}" }
        cmd, param = parse_response(data).values_at(:cmd, :param)

        return :abort if param =~ /^ERR/
        return :success if param == 'OK'

        update_status(cmd, param)
        logger.debug "cmd: #{cmd}, param: #{param}"
        return :success
    end

 #      0123456789
 # e.g. NAME=Test Projector
    def parse_response(byte_str)
        split = byte_str.split('=')
        {
            cmd: LOOKUP_COMMANDS[split[0]].to_s,
            param: split[1]
        }
    end

    # Update module state based on device feedback
    def update_status(cmd, param)
        case cmd.to_sym
        when :power
            case param
            when '0'
              self[:power] = false
              self[:power_status] = 'off'
            when '1'
              self[:power] = true
              self[:power_status] = 'on'
            when '2'
              self[:power_status] = 'cooling'
            when '3'
              self[:power_status] = 'warming'
            end
        when :mute, :audio_mute, :video_mute
            self[cmd] = param.to_i == 1
        when :volume
            self[cmd] = param.to_i
        when :input
            self[cmd] = LOOKUP_INPUTS[param]
        when :lamp
            split = param.split(' ')
            self[:lamp_hours] = split[0].to_i
            self[:lamp_status] = split[1].to_i == 1 ? 'on' : 'off'
        when :error_status
            e = {
              "0": :none,
              "1": :warning,
              "2": :error
            }
            fan, lamp, temperature, cover_open, filter, other = param.chars.map {|c| c.to_sym}
            self[:errors] = {
              fan: e[fan],
              lamp: e[lamp],
              temperature: e[temperature],
              cover_open: e[cover_open],
              filter: e[filter],
              other: e[other]
            }
        end
    end
end
