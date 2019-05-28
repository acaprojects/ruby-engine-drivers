# frozen_string_literal: true
# encoding: ASCII-8BIT

require 'singleton'

module Cisco; end
class Cisco::CatalystOffloader
    include Singleton

    class Proxy
        def initialize(reactor, logger, snmp_settings)
            @reactor = reactor
            @logger = logger
            @snmp_settings = snmp_settings
            @defer = nil

            @terminated = false
            @connected = false

            connect
        end

        ParserSettings = {
            callback: lambda do |byte_str|
                return false if byte_str.bytesize < 4
                length = byte_str[0...4].unpack('V')[0] + 4
                return length if byte_str.length >= length
                false
            end
        }.freeze

        def connect(defer = @reactor.defer)
            @connecting = defer.promise
            @tokeniser = ::UV::AbstractTokenizer.new(ParserSettings)

            # Process response data
            @connection = @reactor.tcp { |data, socket|
                @tokeniser.extract(data).each do |response|
                    next unless @defer
                    begin
                        response = Marshal.load(response[4..-1])
                        if response.is_a? Exception
                            @defer.reject response
                        else
                            @defer.resolve response
                        end
                    rescue => e
                        @logger.debug { "OFFLOAD: error loading response #{e.message}" }
                        @defer.reject e
                    end
                end
            }

            # Attempt to connect to offload process
            @connection.connect('127.0.0.1', 30001) { |socket|
                @logger.debug "OFFLOAD: connected to offload task"
                @connected = true
                defer.resolve(true)
                socket.start_read

                write(:client, @snmp_settings)
            }.finally {
                @logger.debug "OFFLOAD: disconnected from offload task"
                @defer&.reject RuntimeError.new('connection lost')
                @defer = nil

                if @connected
                    @connected = false
                    defer = @reactor.defer
                elsif @terminated
                    defer.reject RuntimeError.new('failed to connect')
                end

                if !@terminated
                    @reactor.scheduler.in(4000) do
                        connect(defer) unless @terminated
                    end
                end
            }
        end

        def write(*args)
            raise "connection not ready" unless @connected
            msg =  Marshal.dump(args)
            defer = @defer
            promise = @connection.write("#{[msg.length].pack('V')}#{msg}")
            return promise if defer.nil?

            sched = @reactor.scheduler.in(180_000) do
                defer.reject RuntimeError.new('request timeout')

                if @defer == defer
                    @defer = nil
                    @logger.debug "OFFLOAD: closing connection due to timeout"
                    new_client
                else
                    @logger.debug "OFFLOAD: closing connection due to timeout"
                end
            end
            defer.promise.finally { sched.cancel }
        end

        def disconnect
            @logger.debug "OFFLOAD: worker termination requested"
            @terminated = true
            @connection.close
        end

        # Proxied methods:
        def processing
            @defer
        end

        def promise
            @defer.promise
        end

        def new_setting(snmp_settings)
            @snmp_settings = snmp_settings
            @defer&.reject RuntimeError.new('client closed by user')
            @defer = nil
            @connecting.then { write(:client, snmp_settings) }
        end

        def new_client
            @defer&.reject RuntimeError.new('client closed by user')
            @defer = nil
            @connecting.then { write(:new_client) }
        end

        def close
            @defer&.reject RuntimeError.new('client closed by user')
            @defer = nil
            @connecting.then { write(:close) }
        end

        def query_index_mappings
            raise "processing in progress" if @defer
            @defer = @reactor.defer
            @connecting.then { write(:query_index_mappings) }
            @defer.promise.value
        ensure
            @defer = nil
        end

        def query_interface_status
            raise "processing in progress" if @defer
            @defer = @reactor.defer
            @connecting.then { write(:query_interface_status) }
            @defer.promise.value
        ensure
            @defer = nil
        end

        def query_snooping_bindings
            raise "processing in progress" if @defer
            @defer = @reactor.defer
            @connecting.then { write(:query_snooping_bindings) }
            @defer.promise.value
        ensure
            @defer = nil
        end
    end

    def register(reactor, logger, snmp_settings)
        Libuv::Reactor.default.schedule { start_process } if !defined?(::Rake::Task) && @worker.nil?
        Proxy.new(reactor, logger, snmp_settings)
    end

    def start_process
        return if @worker
        reactor = Libuv::Reactor.default

        # Start the rake task that will do the SNMP processing
        @worker = reactor.spawn('rake', args: "offload:catalyst_snmp[30001]", mode: :inherit)
        @worker.finally do
            STDOUT.puts "offload task closed! Restarting in 5s..."
            reactor.scheduler.in('5s') do
                @worker = nil
                start_process
            end
        end
    end
end
