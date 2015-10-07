module Tripleplay; end

# default URL: http://<serverIP>
# Settings: none

class Tripleplay::XmlRpc
    include ::Orchestrator::Constants


    DECODE_OPTIONS = {
        symbolize_names: true
    }.freeze


    keepalive false
    inactivity_timeout 1500


    def on_load
        on_update
    end
    
    def on_update
    end
    
    def channel(number, box_id)
        logger.debug { "Changing box#{box_id} to channel #{number}" }
        make_req(:SelectChannel, box_id.to_i, number.to_i, name: :channel)
    end

    def channel_up(box_id)
        logger.debug { "Channel up on box#{box_id}" }
        make_req(:ChannelUp, box_id.to_i, name: :channel)
    end

    def channel_down(box_id)
        logger.debug { "Channel down on box#{box_id}" }
        make_req(:ChannelDown, box_id.to_i, name: :channel)
    end

    def reboot(box_id)
        logger.debug { "Reboot box#{box_id}" }
        make_req(:Reboot, box_id.to_i, name: :Reboot)
    end

    def play_vod(filename, box_id)
        logger.debug { "Play #{filename} on box#{box_id}" }
        make_req(:ChangePortalPage, box_id.to_i, :watch_video, {
            vodItem: filename
        }, name: :Reboot)
    end


    protected


    def make_req(method, *params, **opts)
        json = {
            jsonrpc: '2.0',
            method: method,
            params: params
        }.to_json

        opts[:query] = {
            call: json
        }

        get("/triplecare/JsonXmlRpcHandler.php", opts) do |data, resolve|
            logger.debug { "received: #{data[:body]}" }

            if data[:body] == 'true'
                yield if block_given?
                :success
            else
                resp = ::JSON.parse(data[:body], DECODE_OPTIONS)
                logger.warn "error processing request: #{resp[:faultString]} (#{resp[:faultCode]})"
                :abort
            end
        end
    end
end
