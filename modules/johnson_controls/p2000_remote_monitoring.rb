require 'nokogiri'

module JohnsonControls; end

# Works with both the HTTP and raw ASCII protocols
class JohnsonControls::P2000RemoteMonitoring
    include ::Orchestrator::Constants

    descriptive_name 'Johnson P2000 Remote Monitoring'
    generic_name :Security
    default_settings port: 38000

    # UDP is stateless. We won't actually send or receive anything
    # effectively wanted a logic module that could be added to multiple
    # systems as this is a special case module
    udp_port 38000


    module SignalServer
        SUCCESS = "HTTP/1.1 200 OK\r\n\r\n"

        def post_init(logger, thread, mod)
            @logger = logger
            @thread = thread
            @mod = mod

            @buffer = ::UV::BufferedTokenizer.new({
                indicator: "<P2000Message>",
                delimiter: "</P2000Message>"
            })
        end

        def on_connect(transport)
            # Someone connected (we could whitelist IPs for security)
            ip, port = transport.peername
            logger.info "P2000 Connection from: #{ip}:#{port}"
        end


        attr_reader :logger, :thread


        def on_read(data, *args)
            begin
                @buffer.extract(data).each do |request|
                    logger.debug { "P2000 Sent: #{request}" }
                    process_signal(request)
                end
            rescue => e
                logger.print_error(e, "error extracting data from: #{data.inspect} in on_read callback")
            end
        end

        def process_signal(raw)
            begin
                write SUCCESS
            rescue
                # We don't want to fail if the response fails.
                # Frankly we don't care.
            end
            begin
                signal = "<P2000Message>#{raw}</P2000Message>"
                @mod.received signal
            rescue => e
                logger.print_error(e, "error parsing request in process_signal: #{raw.inspect}")
            end
        end
    end


    def on_load
        on_update
    end

    def on_update
        # Ensure server is stopped
        on_unload

        # Configure server
        port = setting(:port) || 38000
        @server = UV.start_server '0.0.0.0', port, SignalServer, logger, thread, self

        logger.info "P2000 signal server started"
    end

    def on_unload
        if @server
            @server.close
            @server = nil

            # Stop the server if started
            logger.info "server stopped"
        end
    end

    Types = {
        28673 => :RealTime,
        28675 => :Audit,
        3 => :Alarm
    }

    RealTime = {
        68 => :LocalGrant,
        65 => :HostGrant
    }

    def received(xml)
        xml_doc  = Nokogiri::XML(xml)
        type = xml_doc.xpath("//MessageBase//MessageType").children.to_s.to_i
        subtype = xml_doc.xpath("//MessageBase//MessageSubType").children.to_s.to_i
        name = xml_doc.xpath("//MessageBase//ItemName").children.to_s

        case Types[type]
        when :RealTime
            case RealTime[subtype]
            when :LocalGrant, :HostGrant
                process_access_grant(xml_doc)
            end
        end
    end

    def process_access_grant(xml_doc)
        version = xml_doc.xpath("//MessageDetails").length

        first = nil
        last = nil
        staff_id = nil
        panel_id = nil
        panel_name = nil
        term_id = nil
        term_name = nil

        if version == 0  # P2000 v4
            first = xml_doc.xpath("//TransactionDetails//EntityFirstName").children.to_s
            last = xml_doc.xpath("//TransactionDetails//EntityName").children.to_s

            staff_id = xml_doc.xpath("//TransactionDetails//IdentifierNumber").children.to_s

            panel_id = xml_doc.xpath("//TransactionDetails//PanelID").children.to_s
            panel_name = xml_doc.xpath("//TransactionDetails//PanelName").children.to_s
            term_id = xml_doc.xpath("//TransactionDetails//TerminalID").children.to_s
            term_name = xml_doc.xpath("//TransactionDetails//TerminalName").children.to_s
        else # P2000 v3
            first = xml_doc.xpath("//MessageDetails//CardholderFirstName").children.to_s
            last = xml_doc.xpath("//MessageDetails//CardholderLastName").children.to_s

            staff_id = xml_doc.xpath("//MessageDetails//CardholderEmployeeID").children.to_s

            panel_id = xml_doc.xpath("//MessageDetails//PanelID").children.to_s
            panel_name = xml_doc.xpath("//MessageDetails//PanelName").children.to_s
            term_id = xml_doc.xpath("//MessageDetails//TerminalID").children.to_s
            term_name = xml_doc.xpath("//MessageDetails//TerminalName").children.to_s
        end

        data = {
            firstname: first,
            lastname: last,
            staff_id: staff_id,
            panel_id: panel_id,
            panel_name: panel_name,
            term_id: term_id,
            term_name: term_name
        }

        # Make this information available to listeners
        self[term_id.to_s] = data
        self[term_name] = data
    end
end
