require 'shellwords'
require 'set'


module Cisco; end
module Cisco::TelePresence; end


class Cisco::TelePresence::SxSeries
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 4999   # GlobalCache IP -> Serial port
    descriptive_name 'Cisco TelePresence'
    generic_name :VidConf

    # Communication settings
    tokenize delimiter: "\r\n"


    def on_load
    end
    
    def on_update
    end
    
    def connected
        @polling_timer = schedule.every('55s') do
            logger.debug "-- Polling SX80"
        end
    end
    
    def disconnected
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end



    def audio(*args, **options)
        command :audio, *args, params(options)
    end

    def history(cmd, options = {})
        command :CallHistroy, cmd, params(options)
    end


    CallCommands ||= Set.new([:accept, :reject, :disconnect, :hold, :join, :resume, :ignore])
    def call(cmd, call_id = @last_call_id, options = {})
        options[:CallId] = call_id
        command :call, cmd, params(options)
    end

    # Options include: Protocol, CallRate, CallType, DisplayName, Appearance
    def dial(number, options = {})
        options[:Number] = number
        command :dial, params(options)
    end

    # left, right, up, down, zoomin, zoomout
    def far_end_camera(action, call_id = @last_call_id)
        req = action.downcase.to_sym
        if req == :stop
            command :FarEndControl, :Camera, :Stop, "CallId:#{call_id}"
        else
            command :FarEndControl, :Camera, :Move, "CallId:#{call_id} Value:#{req}"
        end
    end

    # Source is a number from 0..15
    def far_end_source(source, call_id = @last_call_id)
        command :FarEndControl, :Source, :Select, "CallId:#{call_id} SourceId:#{source}"
    end



    # Also supports stop
    def presentation(action = :start)

    end

    def save_preset(name)

    end

    def preset(name)

    end

    # pip / 
    def video

    end

    
    
    
    def received(data, resolve, command)
        logger.debug "Tele sent #{data}"
        

        
        return :success
    end
    
    
    protected


    def params(opts = nil, **options)
        opts ||= options
        return nil if opts.empty?

        cmd = ''
        opts.each do |key, value|
            cmd << key
            cmd << ':'
            cmd << value
            cmd << ' '
        end
        cmd.chop!
        cmd
    end
    

    def command(*args, **options)
        args.reject! { |item| item.blank? }

        cmd = "xcommand #{args.join(' ')}"
        value = options.delete(:value)
        if value
            if value.include? ' '
                value = "\"#{value}\""
            end
            cmd << ': '
            cmd << value
        end
        do_send cmd, options
    end

    def status(*args, **options)
        args.reject! { |item| item.blank? }
        do_send "xstatus #{args.join(' ')}", options
    end

    def do_send(command, options)
        send "#{command}\r\n", options
    end
end

