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
        reserve_time: 5.minutes.to_i
    })

    def on_load
        @check_interface = ::Set.new
        @reserved_interface = ::Set.new
        self[:interfaces] = [] # This will be updated via query

        on_update

        # Load the current state of the switch from the database
        query = ::Aca::Tracking::SwitchPort.find_by_switch_ip(remote_address)
        query.each do |detail|
            details = detail.details
            interface = detail.interface
            self[interface] = details

            if details.connected
                @check_interface << interface
            elsif details.reserved
                @reserved_interface << interface
            end
        end

        self[:interfaces] = @check_interface.to_a
        self[:reserved] = @reserved_interface.to_a
    end

    def on_update
        self[:name] = @switch_name = setting(:switch_name)
        self[:ip_address] = remote_address
        self[:building] = setting(:building)
        self[:level] = setting(:level)

        @reserve_time = setting(:reserve_time) || 0
        @snooping ||= []
    end

    def connected
        schedule.in(1000) { query_connected_devices }
        schedule.every('1m') do
            query_connected_devices
            check_reservations if @reserve_time > 0
        end
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

    def query_connected_devices
        logger.debug { "Querying for connected devices" }
        query_interface_status
        schedule.in(3000) { query_snooping_bindings }
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

        # Interface change detection
        # 07-Aug-2014 17:28:26 %LINK-I-Up:  gi2
        # 07-Aug-2014 17:28:31 %STP-W-PORTSTATUS: gi2: STP status Forwarding
        # 07-Aug-2014 17:44:43 %LINK-I-Up:  gi2, aggregated (1)
        # 07-Aug-2014 17:44:47 %STP-W-PORTSTATUS: gi2: STP status Forwarding, aggregated (1)
        # 07-Aug-2014 17:45:24 %LINK-W-Down:  gi2, aggregated (2)
        if data =~ /%LINK/
            interface = normalise(data.split(',')[0].split(/\s/)[-1])

            if data =~ /Up:/
                logger.debug { "Interface Up: #{interface}" }
                remove_reserved(interface)
                @check_interface << interface

                # Delay here is to give the PC some time to negotiate an IP address
                # schedule.in(3000) { query_snooping_bindings }
            elsif data =~ /Down:/
                logger.debug { "Interface Down: #{interface}" }
                remove_lookup(interface)
            end

            self[:interfaces] = @check_interface.to_a

            return :success
        end

        if data.start_with?("Total number")
            logger.debug { "Processing #{@snooping.length} bindings" }

            checked = Set.new

            # Newest lease first
            @snooping.sort! { |a, b| b[0] <=> a[0] }

            # Ignore any duplicates
            @snooping.each do |lease, mac, ip, interface|
                next if checked.include?(interface)
                checked << interface

                iface = self[interface] || ::Aca::Tracking::StaticDetails.new

                if iface.ip != ip || iface.mac != mac
                    logger.debug { "New connection on #{interface} with #{ip}: #{mac}" }

                    # NOTE:: Same as username found
                    details = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{remote_address}-#{interface}") || ::Aca::Tracking::SwitchPort.new
                    reserved = details.connected(mac, @reserve_time, {
                        device_ip: ip,
                        switch_ip: remote_address,
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
                        details = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{remote_address}-#{interface}") || ::Aca::Tracking::SwitchPort.new
                        reserved = details.connected(mac, @reserve_time, {
                            device_ip: ip,
                            switch_ip: remote_address,
                            hostname: @hostname,
                            switch_name: @switch_name,
                            interface: interface
                        })

                        # ip, mac, reserved?, clash?
                        self[interface] = details.details
                    end

                elsif not iface.reserved
                    # We don't know the user who is at this desk...
                    details = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{remote_address}-#{interface}")
                    reserved = details.check_for_user(@reserve_time)
                    self[interface] = details.details if reserved

                elsif iface.clash
                    # There was a reservation clash - is there still a clash?
                    details = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{remote_address}-#{interface}")
                    reserved = details.check_for_user(@reserve_time)
                    self[interface] = details.details if !details.clash?
                end
            end

            @snooping.clear

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
            @check_interface << interface.downcase
            self[:interfaces] = @check_interface.to_a
            return :success

        elsif entries.include?('notconnect')
            interface = entries[0].downcase
            return :success unless @check_interface.include? interface

            # Delete the lookup records
            logger.debug { "Interface Down: #{interface}" }
            remove_lookup(interface)
            self[:interfaces] = @check_interface.to_a
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

                    if ::IPAddress.valid? ip
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
        # We are no longer interested in this interface
        @check_interface.delete(interface)

        # Update the status of the switch port
        model = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{remote_address}-#{interface}")
        if model
            notify = model.disconnected
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

    def format(mac)
        mac.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
    end

    def check_reservations
        remove = []

        # Check if the interfaces are still reserved
        @reserved_interface.each do |interface|
            details = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{remote_address}-#{interface}")
            remove << interface unless details.reserved?
            self[interface] = details.details
        end

        # Remove them from the reserved list if not
        if remove.present?
            @reserved_interface -= remove
            self[:reserved] = @reserved_interface.to_a
        end
    end

    def normalise(interface)
        # Port-channel == po
        interface.downcase.gsub('tengigabitethernet', 'te').gsub('gigabitethernet', 'gi').gsub('fastethernet', 'fa')
    end
end
