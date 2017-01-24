require 'shellwords'
require 'set'
require 'protocols/telnet'

=begin

Trying 10.243.218.xxx...
Connected to 10.243.218.xxx.
Escape character is '^]'.

Linux 3.4.86-100 (localhost) (1)

login: admin
Password:
Welcome to XXXXXX
Cisco Codec Release TC7.3.3.c84180a
SW Release Date: 2015-06-12
*r Login successful


require 'socket'
s = TCPSocket.open '10.243.218.235', 23
result = s.recv(100)
# => "\xFF\xFD\x18\xFF\xFD \xFF\xFD#\xFF\xFD'"

=end

module Cisco; end
module Cisco::TelePresence; end


class Cisco::TelePresence::SxTelnet
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
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
        do_send (setting(:username) || :admin), wait: false, delay: 200, priority: 98
        do_send setting(:password), wait: false, delay: 200, priority: 97
        do_send "Echo off", wait: false, priority: 96
    end
    
    def disconnected
        # Ensures the buffer is cleared
        new_telnet_client
    end
    
    
    protected


    def new_telnet_client
        @telnet = Protocols::Telnet.new do |data|
            send data, priority: 99, wait: false
        end
    end


    def params(opts = {})
        return nil if opts.empty?

        cmd = ''
        opts.each do |key, value|
            next if value.blank?
            cmd << key.to_s
            cmd << ':'
            val = value.to_s.gsub(/[^\w\s\.\:\@\#\*]/, '').strip
            if val.include? ' '
                cmd << '"'
                cmd << val
                cmd << '"'
            else
                cmd << val
            end
            cmd << ' '
        end
        cmd.chop!
        cmd
    end
    

    def command(*args, **options)
        args.reject! { |item| item.blank? }
        cmd = "xcommand #{args.join(' ')}"
        do_send cmd, options
    end

    def status(*args, **options)
        args.reject! { |item| item.blank? }
        do_send "xstatus #{args.join(' ')}", options
    end

    def configuration(*args, **options)
        args.reject! { |item| item.blank? }
        do_send "xConfiguration #{args.join(' ')}", options
    end

    def do_send(command, options = {})
        logger.debug { "requesting #{command}" }
        send @telnet.prepare(command), options
    end
end

