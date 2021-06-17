require 'shellwords'
require 'set'

=begin

Welcome to XXXX_Room
Cisco Codec Release ce 8.2.1 Final e9daf06 2016-06-28
SW Release Date: 2016-06-28
*r Login successful

OK

=end

module Cisco; end
module Cisco::TelePresence; end


class Cisco::TelePresence::SxSsh
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 22
    implements :ssh

    # Communication settings
    tokenize delimiter: "\n",
             wait_ready: "OK" # *r Login successful\n\nOK
    clear_queue_on_disconnect!

    default_settings({
        ssh: {
            username: 'admin',
            password: ''
        }
    })


    def on_load
        # Allow more ignores
        defaults max_waits: 100
    end


    def connected
        do_send "Echo off", wait: false, priority: 96
    end

    def disconnected; end


    protected


    def params(opts = {})
        return nil if opts.empty?

        cmd = String.new
        opts.each do |key, value|
            next if value.blank?
            cmd << key.to_s
            cmd << ':'
            val = value.to_s.gsub(/[^\w\s\.\:\@\#\*\-]/, '').strip
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
        send "#{command}\n", options
    end
end
