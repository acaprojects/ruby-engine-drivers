# frozen_string_literal: true
# encoding: ASCII-8BIT

module Cisco; end
module Cisco::Switch; end

require 'set'
::Orchestrator::DependencyManager.load('Aca::Tracking::SwitchPort', :model, :force)
::Aca::Tracking::SwitchPort.ensure_design_document!

class Cisco::Switch::SnoopingCatalyst
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
    include ::Orchestrator::Security

    descriptive_name 'Cisco Catalyst Switch IP Snooping'
    generic_name :Snooping

    # Discovery Information
    tcp_port 22
    implements :ssh

    # Communication settings
    tokenize delimiter: /\n|-- /
    clear_queue_on_disconnect!

    default_settings({
        ssh: {
            username: :cisco,
            password: :cisco,
            auth_methods: [
                :none,
                :publickey,
                :password
            ]
        },
        building: 'building_code',
        reserve_time: 5.minutes.to_i,
        ignore_macs: {
            "Cisco Phone Dock": "7001b5"
        },
        temporary_macs: {},
        discovery_polling_period: 90
    })

    def on_load
        # Interfaces that indicate they have a device connected
        @check_interface = ::Set.new

        # Interfaces that we know are connected to the network
        @connected_interfaces = ::Set.new

        @reserved_interface = ::Set.new
        self[:interfaces] = [] # This will be updated via query

        begin
            on_update

            # Load the current state of the switch from the database
            query = ::Aca::Tracking::SwitchPort.find_by_switch_ip(@remote_address)
            query.each do |detail|
                details = detail.details
                interface = detail.interface
                self[interface] = details

                if details.connected
                    @check_interface << interface
                    @connected_interfaces << interface
                elsif details.reserved
                    @reserved_interface << interface
                end
            end
        rescue => error
            logger.print_error error, 'loading persisted details'
        end

        self[:interfaces] = @connected_interfaces.to_a
        self[:reserved] = @reserved_interface.to_a
    end

    def on_update
        @temp_interface_macs ||= {}
        @interface_macs ||= {}

        @remote_address = remote_address.downcase
        @ignore_macs = ::Set.new((setting(:ignore_macs) || {}).values)
        @temporary = ::Set.new((setting(:temporary_macs) || {}).values)
        @polling_period = setting(:discovery_polling_period) || 90

        self[:name] = @switch_name = setting(:switch_name)
        self[:ip_address] = @remote_address
        self[:building] = setting(:building)
        self[:level] = setting(:level)

        self[:last_successful_query] ||= 0

        @reserve_time = setting(:reserve_time) || 0
        @snooping ||= []
    end

    def connected
        schedule.in(1000) { query_connected_devices }
        schedule.every('1m') { query_connected_devices }
    end

    def disconnected
        schedule.clear
    end

    # Don't want the every day user using this method
    protect_method :run
    def run(command, options = {})
        do_send command, **options
    end

    def query_snooping_bindings
        do_send 'show ip dhcp snooping binding'
    end

    def query_interface_status
        do_send 'show interfaces status'
    end

    def query_mac_addresses
        @temp_interface_macs.clear
        do_send 'show mac address-table'
    end

    def query_connected_devices
        logger.debug { "Querying for connected devices" }
        query_interface_status.then do
            schedule.in(3000) do
                query_mac_addresses.then do
                    schedule.in(3000) do
                        p = query_snooping_bindings
                        p.then { schedule.in(10000) { check_reservations; nil }; nil } if @reserve_time > 0
                        nil
                    end
                    nil
                end
                nil
            end
            nil
        end
        nil
    end

    def update_reservations
        check_reservations
    end

    protected

    def received(data, resolve, command)
        logger.debug { "Switch sent #{data}" }

        # determine the hostname
        if @hostname.nil?
            parts = data.split('>')
            if parts.length == 2
                self[:hostname] = @hostname = parts[0]
                return :success # Exit early as this line is not a response
            end
        end

        # Detect more data available
        # ==> --More--
        if data =~ /More/
            send(' ', priority: 99, retries: 0)
            return :success
        end

        # Interface MAC Address detection
        # 33    e4b9.7aa5.aa7f    STATIC      Gi3/0/8
        # 10    f4db.e618.10a4    DYNAMIC     Te2/0/40
        if data =~ /STATIC|DYNAMIC/
            parts = data.split(/\s+/).reject(&:empty?)
            mac = format(parts[1])
            interface = normalise(parts[-1])

            @temp_interface_macs[interface] = mac if mac && interface

            return :success
        end

        # Interface change detection
        # 07-Aug-2014 17:28:26 %LINK-I-Up:  gi2
        # 07-Aug-2014 17:28:31 %STP-W-PORTSTATUS: gi2: STP status Forwarding
        # 07-Aug-2014 17:44:43 %LINK-I-Up:  gi2, aggregated (1)
        # 07-Aug-2014 17:44:47 %STP-W-PORTSTATUS: gi2: STP status Forwarding, aggregated (1)
        # 07-Aug-2014 17:45:24 %LINK-W-Down:  gi2, aggregated (2)
        if data =~ /%LINK/
            interface = normalise(data.split(',')[0].split(/\s/)[-1])

            if data =~ /Up:/
                logger.debug { "Notify Up: #{interface}" }
                remove_reserved(interface)
                @check_interface << interface
                @connected_interfaces << interface

                # Delay here is to give the PC some time to negotiate an IP address
                # schedule.in(3000) { query_snooping_bindings }
            elsif data =~ /Down:/
                logger.debug { "Notify Down: #{interface}" }
                # We are no longer interested in this interface
                @connected_interfaces.delete(interface)
                @check_interface.delete(interface)
                remove_lookup(interface)
                self[:reserved] = @reserved_interface.to_a
            end

            self[:interfaces] = @check_interface.to_a

            return :success
        end

        if data.start_with?("Total number")
            logger.debug { "Processing #{@snooping.length} bindings" }

            checked = Set.new
            @interface_macs = @temp_interface_macs unless @temp_interface_macs.empty?
            #checked_interfaces = Set.new

            # Newest lease first
            # @snooping.sort! { |a, b| b[0] <=> a[0] }

            # NOTE:: Same as snooping_catalyst_snmp.rb
            # Ignore any duplicates
            @snooping.each do |lease, mac, ip, interface|
                next unless @check_interface.include?(interface)
                next unless @interface_macs[interface] == mac

                checked << interface
                iface = self[interface] || ::Aca::Tracking::StaticDetails.new

                if iface.ip != ip || iface.mac != mac
                    logger.debug { "New connection on #{interface} with #{ip}: #{mac}" }

                    # NOTE:: Same as username found
                    details = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{@remote_address}-#{interface}") || ::Aca::Tracking::SwitchPort.new
                    details.connected(mac, @reserve_time, {
                        device_ip: ip,
                        switch_ip: @remote_address,
                        hostname: @hostname,
                        switch_name: @switch_name,
                        interface: interface
                    })

                    # ip, mac, reserved?, clash?
                    self[interface] = details.details

                elsif iface.username.nil?
                    username = ::Aca::Tracking::SwitchPort.bucket.get("macuser-#{mac}", quiet: true)
                    if username
                        logger.debug { "Found #{username} at #{ip}: #{mac}" }

                        # NOTE:: Same as new connection
                        details = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{@remote_address}-#{interface}") || ::Aca::Tracking::SwitchPort.new
                        details.connected(mac, @reserve_time, {
                            device_ip: ip,
                            switch_ip: @remote_address,
                            hostname: @hostname,
                            switch_name: @switch_name,
                            interface: interface
                        })

                        # ip, mac, reserved?, clash?
                        self[interface] = details.details
                    end

                elsif !iface.reserved
                    # We don't know the user who is at this desk...
                    details = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{@remote_address}-#{interface}")
                    reserved = details.check_for_user(@reserve_time)
                    self[interface] = details.details if reserved

                elsif iface.clash
                    # There was a reservation clash - is there still a clash?
                    details = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{@remote_address}-#{interface}")
                    details.check_for_user(@reserve_time)
                    self[interface] = details.details unless details.clash?
                end
            end

            # @interface_macs
            @connected_interfaces = @check_interface & @interface_macs.keys
            self[:interfaces] = @connected_interfaces.to_a
            self[:reserved] = @reserved_interface.to_a
            @snooping.clear

            self[:last_successful_query] = Time.now.to_i

            return :success
        end

        # Grab the parts of the response
        entries = data.split(/\s+/)

        # show interfaces status
        # Port    Name               Status       Vlan       Duplex  Speed Type
        # Gi1/1                      notconnect   1            auto   auto No Gbic
        # Fa6/1                      connected    1          a-full  a-100 10/100BaseTX
        if entries.include?('connected')
            interface = entries[0].downcase
            return :success if @check_interface.include? interface

            logger.debug { "Interface Up: #{interface}" }
            remove_reserved(interface)
            @check_interface << interface
            return :success

        elsif entries.include?('notconnect')
            interface = entries[0].downcase
            return :success unless @check_interface.include? interface

            # Delete the lookup records
            logger.debug { "Interface Down: #{interface}" }
            @check_interface.delete(interface)
            remove_lookup(interface)
            return :success
        end

        # We are looking for MAC to IP address mappings
        # =============================================
        # MacAddress          IpAddress        Lease(sec)  Type           VLAN  Interface
        # ------------------  ---------------  ----------  -------------  ----  --------------------
        # 00:21:CC:D5:33:F4   10.151.130.1     16283       dhcp-snooping   113   GigabitEthernet3/0/43
        # Total number of bindings: 3
        if @check_interface.present? && !entries.empty?
            interface = normalise(entries[-1])

            # We only want entries that are currently active
            if @check_interface.include? interface

                # Ensure the data is valid
                mac = entries[0]
                if mac =~ /^(?:[[:xdigit:]]{1,2}([-:]))(?:[[:xdigit:]]{1,2}\1){4}[[:xdigit:]]{1,2}$/
                    mac = format(mac)
                    ip = entries[1]

                    if ::IPAddress.valid?(ip) && !@ignore_macs.include?(mac[0..5])
                        @snooping << [entries[2].to_i, mac, ip, interface]
                    end
                end
            end
        end

        :success
    end

    protected

    def do_send(cmd, **options)
        logger.debug { "requesting #{cmd}" }
        send("#{cmd}\n", options)
    end

    def remove_lookup(interface)
        # Update the status of the switch port
        model = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{@remote_address}-#{interface}")
        if model
            # Check if MAC address is black listed.
            # We want to remove the discovery information for the MAC
            # We also need to prevent it being re-discovered for the polling
            # period as the next person to connect will be mis-associated
            # Need to create a database entry for the MAC with a TTL
            mac = model.mac_address
            temporary = if (mac && @temporary.include?(mac[0..5]))
                logger.info { "removing temporary MAC for #{model.username} with #{model.mac_address} at #{model.desk_id}" }
                @polling_period
            else
                0
            end
            notify = model.disconnected(temporary: temporary)
            details = model.details
            self[interface] = details

            # notify user about reserving their desk
            if notify
                self[:disconnected] = details
                @reserved_interface << interface
            end
        else
            self[interface] = nil
        end
    end

    def remove_reserved(interface)
        return unless @reserved_interface.include? interface
        @reserved_interface.delete interface
        self[:reserved] = @reserved_interface.to_a
    end

    def check_reservations
        remove = []

        # Check if the interfaces are still reserved
        @reserved_interface.each do |interface|
            details = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{@remote_address}-#{interface}")
            remove << interface unless details.reserved?
            self[interface] = details.details
        end

        # Remove them from the reserved list if not
        return unless remove.present?

        @reserved_interface -= remove
        self[:reserved] = @reserved_interface.to_a
    end

    def format(mac)
        mac.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
    end

    def normalise(interface)
        # Port-channel == po
        interface.downcase.gsub('tengigabitethernet', 'te').gsub('twogigabitethernet', 'tw').gsub('gigabitethernet', 'gi').gsub('fastethernet', 'fa')
    end
end
