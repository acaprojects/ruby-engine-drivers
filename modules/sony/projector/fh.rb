# encoding: ASCII-8BIT
# frozen_string_literal: true

require 'shellwords'

module Sony; end
module Sony::Projector; end

# Device Protocol Documentation: https://drive.google.com/a/room.tools/file/d/1C0gAWNOtkbrHFyky_9LfLCkPoMcYU9lO/view?usp=sharing

class Sony::Projector::Fh
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    descriptive_name 'Sony Projector FH Series'
    generic_name :Display

    # Communication settings
    tokenize delimiter: "\x0D"
    delay on_receive: 50, between_sends: 50


    def on_load
        self[:type] = :projector
    end


    def connected
        schedule.every('60s') { do_poll }
    end

    def disconnected
        schedule.clear
    end

    def power(state)
        state = is_affirmative?(state)
        target = state ? "on" : "off"
        set("power", target).then { self[:power] = state }
    end

    def power?
        get("power_status").then do |response|
            self[:power] = response == "on"
        end
    end

    def mute(state = true)
        state = is_affirmative?(state)
        target = state ? "on" : "off"
        set("blank", target).then { self[:mute] = state }
    end

    def unmute
        mute(false)
    end

    def mute?
        get("blank").then do |response|
            self[:mute] = response == "on"
        end
    end

    INPUTS = {
        hdmi:   'hdmi1',       #Input C
        dvi:    'dvi1',        #Input B
        video:  'video1',
        svideo: 'svideo1',
        rgb:    'rgb1',        #Input A
        hdbaset:'hdbaset1',    #Input D
        inputa: 'input_a',
        inputb: 'input_b',
        inputc: 'input_c',
        inputd: 'input_d',
        inpute: 'input_e'
    }
    INPUTS.merge!(INPUTS.invert)

    def switch_to(input)
        target=input.to_sym
        set("input", INPUTS[target]).then { self[:input] = target }
    end

    def input?
        get("input").then do |response|
            self[:input] = response.to_sym
        end
    end

    def lamp_time?
        #get "timer"
    end


    #
    # Automatically creates a callable function for each command
    #    http://blog.jayfields.com/2007/10/ruby-defining-class-methods.html
    #    http://blog.jayfields.com/2008/02/ruby-dynamically-define-method.html
    #
    [:contrast, :brightness, :color, :hue, :sharpness].each do |command|
        # Query command
        define_method :"#{command}?" do
            get "#{command}"
        end

        # Set value command
        define_method command do |level|
            level = in_range(level, 0x64)
            set command, level
        end
    end

    protected

    def received(response, resolve, command)
        logger.debug { "Sony proj sent: #{response.inspect}" }

        data = response.strip.downcase.shellsplit
        logger.debug { "Sony proj sent: #{data}" }

        return :success if data[0] == "ok"
        return :abort if data[0] == "err_cmd"
        #return data[1] if data.length > 1
        data[0]
    end

    def do_poll
        power?.finally do
            if self[:power]
                input?
                mute?
                lamp_time?
            end
        end
    end

    def get(path, **options)
        cmd = "#{path} ?\r\n"
        logger.debug { "requesting: #{cmd}" }
        send(cmd, options)
    end

    def set(path, arg, **options)
        cmd = "#{path} \"#{arg}\"\r\n"
        logger.debug { "sending: #{cmd}" }
        send(cmd, options)
    end
end
