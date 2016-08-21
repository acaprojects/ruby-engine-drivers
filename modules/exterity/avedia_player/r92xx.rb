require 'shellwords'
require 'set'
require 'protocols/telnet'



module Exterity; end
module Exterity::AvediaPlayer; end


class Exterity::AvediaPlayer::R92xx
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    descriptive_name 'Exterity Avedia Player (R92xx)'
    generic_name :IPTV
    tcp_port 23

    # Communication settings
    tokenize delimiter: "\r",
             wait_ready: "login:"
    clear_queue_on_disconnect!



    def on_load
        # Allow more ignores
        defaults max_waits: 100

        # Implement the Telnet protocol
        new_telnet_client
        config before_buffering: proc { |data|
            @telnet.buffer data
        }
    end

    
    def connected
        @ready = false

        # Disable echo (Doesn't look like Exterity supports this option)
        # send "#{Protocols::Telnet::IAC}#{Protocols::Telnet::DONT}#{Protocols::Telnet::OPT_ECHO}", wait: false, delay: 50, priority: 99

        # Login
        do_send (setting(:username) || 'admin'), wait: false, delay: 200, priority: 98
        do_send (setting(:password) || 'labrador'), wait: false, delay: 200, priority: 97

        # Select open shell option
        do_send '6', wait: false, delay: 200, priority: 96

        # Launch command processor
        do_send './usr/bin/serialCommandInterface', wait: false, delay: 200, priority: 95

        # We need to disconnect if we don't see the serialCommandInterface after a certain amount of time
        schedule.in('5s') do
            if not @ready
                logger.error 'Exterity connection failed to be ready after 5 seconds. Check username and password.'
                disconnect
            end
        end

        # We want to buffer the sub commands too
        @buffer = ::UV::BufferedTokenizer.new({
            indicator: '^',
            delimiter: '!'
        })

        @polling_timer = schedule.every('60s') do
            logger.debug '-- Polling Exterity Player'
            tv_info
        end
    end
    
    def disconnected
        # Ensures the buffer is cleared
        new_telnet_client

        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end


    def channel(number, _ = nil)
        if [Integer, Fixnum].include? number.class
            set :playChannelNumber, number
        else
            stream number
        end
    end

    def stream(uri, _ = nil)
        set :playChannelUri, uri
    end

    def dump
        do_send '^dump!', name: :dump
    end

    def help
        do_send '^help!', name: :help
    end

    def reboot
        remote :reboot
    end

    def tv_info
        get :tv_info
    end

    def version
        get :SoftwareVersion
    end

    def manual(cmd)
        do_send cmd
    end
    
    
    protected


    def received(data, resolve, command)
        data = data.strip

        logger.debug { "Exterity sent #{data}" }

        if @ready
            # Ignore echos
            if command && command[:data].include?(data)
                return :ignore
            end

            # Extract response
            @buffer.extract(data).each do |resp|
                process_resp(resp, resolve, command)
            end
        elsif data =~ /Exterity Control Interface| Exit/i
            @ready = true
            version
        end

        :success
    end

    def process_resp(data, resolve, command)
        logger.debug { "Resp details #{data}" }

        parts = data.split ':'

        case parts[0].to_sym
        when :error
            if command
                logger.warn "Error when requesting: #{command[:data].strip}"
            else
                logger.warn "Error response received"
            end
        when :tv_info
            self[:tv_info] = parts[1]
        when :SoftwareVersion
            self[:version] = parts[1]
        end
    end

    def set(command, data, options = {})
        options[:name] = :"set_#{command}" unless options[:name]
        do_send("^set:#{command}:#{data}!", options)
    end

    def get(status, options = {})
        do_send("^get:#{status}!", options)
    end

    def remote(cmd, options = {})
        do_send("^send:#{cmd}!", options)
    end


    def new_telnet_client
        @telnet = Protocols::Telnet.new do |data|
            send data, priority: 99, wait: false
        end
    end

    def do_send(command, options = {})
        logger.debug { "requesting #{command}" }
        send @telnet.prepare(command), options
    end
end

