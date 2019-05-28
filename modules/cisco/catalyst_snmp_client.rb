# frozen_string_literal: true
# encoding: ASCII-8BIT

require 'netsnmp'

module Cisco; end
module Cisco::Switch;
    AddressType = {
        0  => :unknown,
        1  => :ipv4,
        2  => :ipv6,
        3  => :ipv4z,
        4  => :ipv6z,
        16 => :dns
    }.freeze

    AcceptAddress = [:ipv4, :ipv6, :ipv4z, :ipv6z].freeze

    BindingStatus = {
        1 => :active,
        2 => :not_in_service,
        3 => :not_ready,
        4 => :create_and_go,
        5 => :create_and_wait,
        6 => :destroy
    }.freeze

    # cdsBindingsEntry
    EntryParts = {
        '1' => :vlan,        # Cisco has made this not-accessible
        '2' => :mac_address, # Cisco has made this not-accessible
        '3' => :addr_type,
        '4' => :ip_address,
        '5' => :interface,
        '6' => :leased_time,    # in seconds
        '7' => :binding_status, # can set this to destroy to delete entry
        '8' => :hostname
    }.freeze

    SnoopingEntry = Struct.new(:id, *EntryParts.values) do
        def address_type
            AddressType[self.addr_type]
        end

        def mac
            self.mac_address || self.extract_vlan_and_mac.mac_address
        end

        def get_vlan
            self.vlan || self.extract_vlan_and_mac.vlan
        end

        def ip
            ip_addr = self.ip_address
            return nil unless ip_addr

            case self.address_type
            when :ipv4
                # DISPLAY-HINT "1d.1d.1d.1d"
                # Example response: "0A B2 C4 45"
                ip_addr.split(' ').map { |i| i.to_i(16).to_s }.join('.')
            when :ipv6
                # DISPLAY-HINT "2x:2x:2x:2x:2x:2x:2x:2x"
                # IPAddr will present the IPv6 address in it's short form
                IPAddr.new(ip_addr.gsub(' ', '').scan(/..../).join(':')).to_s
            end
        end

        def extract_vlan_and_mac
            parts = self.id.split('.')
            self.vlan = parts[0].to_i
            self.mac_address = parts[1..-1].map { |i| i.to_i.to_s(16).rjust(2, '0') }.join('')
            self
        end
    end
end

class Cisco::Switch::CatalystSNMPClient
    # version: 1,
    # community: 'public',
    # timeout: 4
    # host:
    # community:
    def initialize(reactor, **snmp_settings)
        @reactor = reactor
        @snmp_settings = snmp_settings

        # flag to indicate if processing is occuring
        @if_mappings = {}
        @defer = nil
    end

    def processing
        @defer
    end

    def promise
        @defer.promise
    end

    def new_client
        close
        @client = NETSNMP::Client.new(@snmp_settings)
    end

    def close
        client = @client
        if @defer
            @defer.promise.finally { client.close }
            @defer.reject RuntimeError.new('client closed by user')
            @defer = nil
        else
            client&.close
        end
    end

    # Index short name lookup
    # ifName: 1.3.6.1.2.1.31.1.1.1.1.xx  (where xx is the ifIndex)
    def query_index_mappings
        raise "processing in progress" if @defer

        client = @client || new_client
        defer = @defer = @reactor.defer

        begin
            mappings = {}

            @reactor.work {
                client.walk(oid: '1.3.6.1.2.1.31.1.1.1.1').each do |oid_code, value|
                    oid_code = oid_code[23..-1]
                    mappings[oid_code.to_i] = value.downcase
                end
            }.value

            @if_mappings = mappings
        ensure
            defer.resolve(true)
            @defer = nil if defer == @defer
        end
    end

    # ifOperStatus: 1.3.6.1.2.1.2.2.1.8.xx == up(1), down(2), testing(3)
    def query_interface_status
        raise "processing in progress" if @defer

        if_mappings = @if_mappings || query_index_mappings

        client = @client || new_client
        defer = @defer = @reactor.defer

        begin
            interfaces_up = []
            interfaces_down = []

            @reactor.work {
                client.walk(oid: '1.3.6.1.2.1.2.2.1.8').each do |oid_code, value|
                    oid_code = oid_code[20..-1]
                    interface = if_mappings[oid_code.to_i]
                    next unless interface

                    case value
                    when 1 # up
                        interfaces_up << interface
                    when 2 # down
                        interfaces_down << interface
                    else
                        next
                    end
                end
            }.value

            [interfaces_down, interfaces_up]
        ensure
            defer.resolve(true)
            @defer = nil if defer == @defer
        end
    end

    # A row instance contains the Mac address, IP address type, IP address, VLAN number, interface number, leased time, and status of this instance.
    # http://www.oidview.com/mibs/9/CISCO-DHCP-SNOOPING-MIB.html
    # http://www.snmplink.org/OnLineMIB/Cisco/index.html#1634
    def query_snooping_bindings
        raise "processing in progress" if @defer

        client = @client || new_client
        defer = @defer = @reactor.defer

        begin
            entries = {}

            @reactor.work {
                client.walk(oid: '1.3.6.1.4.1.9.9.380.1.4.1').each do |oid_code, value|
                    part, entry_id = oid_code[28..-1].split('.', 2)
                    next if entry_id.nil?

                    entry = entries[entry_id] || ::Cisco::Switch::SnoopingEntry.new
                    entry.id = entry_id
                    entry.__send__("#{::Cisco::Switch::EntryParts[part]}=", value)
                    entries[entry_id] = entry
                end
            }.value

            entries
        ensure
            defer.resolve(true)
            @defer = nil if defer == @defer
        end
    end
end
