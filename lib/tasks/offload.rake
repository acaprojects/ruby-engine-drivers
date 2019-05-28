# encoding: ASCII-8BIT
# frozen_string_literal: true

# rake offload:catalyst_snmp['port_number']

namespace :offload do
    desc 'provides a process for offloading SNMP workloads'
    task(:catalyst_snmp, [:tcp_port]) do |_, args|
        require 'uv-rays'
        require File.join(__dir__, '../../modules/cisco/catalyst_snmp_client.rb')
        require File.join(__dir__, '../../modules/cisco/catalyst_offloader.rb')

        port = args[:tcp_port].to_i
        connected = 0
        puts "offload catalyst snmp binding to port #{port}"

        Libuv.reactor.run do |reactor|
            tcp = reactor.tcp
            tcp.bind('0.0.0.0', port) do |client|
                tokeniser = ::UV::AbstractTokenizer.new(::Cisco::CatalystOffloader::Proxy::ParserSettings)
                snmp_client = nil
                client_host = nil
                connected += 1
                STDOUT.puts "total connections: #{connected}"

                client.progress do |data|
                    tokeniser.extract(data).each do |response|
                        begin
                            args = Marshal.load(response[4..-1])
                            if args[0] == :client
                                STDOUT.puts "reloading client with #{args[1]}"
                                client_host = args[1][:host]
                                snmp_client&.close
                                snmp_client = ::Cisco::Switch::CatalystSNMPClient.new(reactor, args[1])
                            else
                                STDOUT.puts "received request #{client_host} #{args[0]}"
                                retval = nil
                                begin
                                    retval = snmp_client.__send__(*args)
                                rescue => e
                                    retval = e
                                end
                                if args[0].to_s.start_with? 'query'
                                    msg =  Marshal.dump(retval)
                                    client.write("#{[msg.length].pack('V')}#{msg}")
                                end
                            end
                        rescue => e
                            STDOUT.puts "failed to marshal request\n#{e.message}\n#{e.backtrace&.join("\n")}"
                        end
                    end
                end
                client.enable_nodelay
                client.start_read
                client.finally do
                    connected -= 1
                    STDOUT.puts "total connections: #{connected}"
                end
            end
            tcp.catch do |e|
                STDOUT.puts "failed to bind port\n#{e.message}\n#{e.backtrace&.join("\n")}"
            end
            tcp.listen(1024)
        end

        puts "offload catalyst snmp closed..."
    end
end
