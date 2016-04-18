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

        do_send (setting(:username) || 'admin'), wait: false, delay: 200, priority: 98
        do_send (setting(:password) || 'labrador'), wait: false, delay: 200, priority: 97
        do_send '6', wait: false, delay: 200, priority: 96
        do_send './usr/bin/serialCommandInterface', wait: false, delay: 200, priority: 95

        # TODO:: We need to disconnect if we don't see the serialCommandInterface after a certain amount of time

        # We want to buffer the sub commands too
        @buffer = ::UV::BufferedTokenizer.new({
            indicator: '^',
            delimiter: '!'
        })

        @polling_timer = schedule.every('60s') do
            logger.debug '-- Polling Exterity Player'
        end
    end
    
    def disconnected
        # Ensures the buffer is cleared
        new_telnet_client

        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end

    # TODO:: Channel selection and power control
    
    
    protected



    def received(data, resolve, command)
        logger.debug { "Exterity sent #{data}" }

        if @ready
            @buffer.extract(data).each do |resp|
                process_resp(resp, resolve, command)
            end
        elsif data =~ /Exterity Control Interface/
            @ready = true
        end

        :success
    end

    def process_resp(data, resolve, command)
        logger.debug { "Resp details #{data}" }

        # TODO:: track status here
    end

    def eci(command, options = {})
        do_send("^#{command}!", options)
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

