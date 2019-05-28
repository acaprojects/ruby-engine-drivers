# frozen_string_literal: true

module Lutron; end

# Documentation: https://aca.im/driver_docs/Lutron/lutron-lighting.pdf
# Login #1: nwk
# Login #2: nwk2

# Login: lutron
# Password: integration

class Lutron::Lighting
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # Discovery Information
    tcp_port 23
    descriptive_name 'Lutron Lighting Gateway'
    generic_name :Lighting

    # Communication settings
    tokenize delimiter: "\r\n"
    wait_response false
    delay between_sends: 100

    def on_load
        on_update
    end

    def on_update
        @login = setting(:login) || 'nwk'
        @trigger_type = setting(:trigger) || :area
    end

    def connected
        send "#{@login}\r\n", priority: 9999

        schedule.every('40s') do
            logger.debug '-- Polling Lutron'
            scene? 1
        end
    end

    def disconnected
        schedule.clear
    end

    def restart
        send_cmd 'RESET', 0
    end

    # on or off
    def lighting(device, state, action = 1)
        level = is_affirmative?(state) ? 100 : 0
        light_level(device, level, 1, 0)
    end


    # ===============
    # OUTPUT COMMANDS
    # ===============

    # dimmers, CCOs, or other devices in a system that have a controllable output
    def level(device, level, rate = 1000, component = :output)
        level = in_range(level.to_i, 100)
        seconds = (rate.to_i / 1000).to_i
        min = seconds / 60
        seconds -= min * 60
        time = "#{min.to_s.rjust(2, '0')}:#{seconds.to_s.rjust(2, '0')}"
        send_cmd component.to_s.upcase, device, 1, level, time
    end

    def blinds(device, action, component = :shadegrp)
        case action.to_s.downcase
        when 'raise', 'up'
            send_cmd component.to_s.upcase, device, 3
        when 'lower', 'down'
            send_cmd component.to_s.upcase, device, 2
        when 'stop'
            send_cmd component.to_s.upcase, device, 4
        end
    end


    # =============
    # AREA COMMANDS
    # =============
    def scene(area, scene, component = :area)
        send_cmd(component.to_s.upcase, area, 6, scene).then do
            scene?(area, component)
        end
    end

    def scene?(area, component = :area)
        send_query component.to_s.upcase, area, 6
    end

    def occupancy?(area)
        send_query 'AREA', area, 8
    end

    def daylight_mode?(area)
        send_query 'AREA', area, 7
    end

    def daylight(area, mode)
        val = is_affirmative?(mode) ? 1 : 2
        send_cmd 'AREA', area, 7, val
    end


    # ===============
    # DEVICE COMMANDS
    # ===============
    def button_press(area, button)
        send_cmd 'DEVICE', area, button, 3
    end

    def led(area, device, state)
        val = if state.is_a?(Integer)
            state
        else
            is_affirmative?(state) ? 1 : 0
        end

        send_cmd 'DEVICE', area, device, 9, val
    end

    def led?(area, device)
        send_query 'DEVICE', area, device, 9
    end


    # =============
    # COMPATIBILITY
    # =============
    def trigger(area, scene)
        scene(area, scene, @trigger_type)
    end

    def light_level(area, level, component = nil, fade = 1000)
        if component
            level(area, level, fade, component)
        else
            level(area, level, fade, :area)
        end
    end


    Errors = {
        '1' => 'Parameter count mismatch',
        '2' => 'Object does not exist',
        '3' => 'Invalid action number',
        '4' => 'Parameter data out of range',
        '5' => 'Parameter data malformed',
        '6' => 'Unsupported Command'
    }

    Occupancy = {
        '1' => :unknown,
        '2' => :inactive,
        '3' => :occupied,
        '4' => :unoccupied
    }

    def received(data, resolve, command)
        logger.debug { "Lutron sent: #{data}" }

        parts = data.split(',')
        component = parts[0][1..-1].downcase

        case component.to_sym
        when :area, :output, :shadegrp
            area = parts[1]
            action = parts[2].to_i
            param = parts[3]

            case action
            when 1 # level
                self[:"#{component}#{area}_level"] = param.to_f
            when 6 # Scene
                self[:"#{component}#{area}"] = param.to_i
            when 7
                self[:"#{component}#{area}_daylight"] = param == '1'
            when 8
                self[:"#{component}#{area}_occupied"] = Occupancy[param]
            end
        when :device
            area = parts[1]
            device = parts[2]
            action = parts[3].to_i

            case action
            when 7 # Scene
                self[:"device#{area}_#{device}"] = parts[4].to_i
            when 9 # LED state
                self[:"device#{area}_#{device}_led"] = parts[4].to_i
            end
        when :error
            logger.warn "error #{parts[1]}: #{Errors[parts[1]]}"
            return :abort
        end

        :success
    end

    protected

    def send_cmd(*command, **options)
        cmd = "##{command.join(',')}"
        logger.debug { "Requesting: #{cmd}" }
        send("#{cmd}\r\n", options)
    end

    def send_query(*command, **options)
        cmd = "?#{command.join(',')}"
        logger.debug { "Requesting: #{cmd}" }
        send("#{cmd}\r\n", options)
    end
end