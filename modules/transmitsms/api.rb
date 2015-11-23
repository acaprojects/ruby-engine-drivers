module Transmitsms; end

class Transmitsms::Api
    include ::Orchestrator::Constants


    DECODE_OPTIONS = {
        symbolize_names: true
    }.freeze


    # Discovery Information
    uri_base 'https://app.wholesalesms.com.au'
    descriptive_name 'Wholesalesms SMS Service'
    generic_name :SMS
    default_settings api_key: 'key here', api_secret: 'secret here'

    # Communication settings
    keepalive false
    inactivity_timeout 1500


    def on_load
        on_update
    end
    
    def on_update
        @api_key = setting(:api_key)
        @api_secret = setting(:api_secret)
    end
    
    def send_sms(message, params = {})
        params[:message] = message
        options = {
            headers: {
                'authorization' => [@api_key, @api_secret]
            },
            body: params
        }

        logger.debug "Requesting SMS: #{params}"

        post('/api/v2/send-sms.json', options) do |data, resolve|
            resp = ::JSON.parse(data[:body], DECODE_OPTIONS)
            if resp[:error][:code] != 'SUCCESS'
                self[:last_error] = resp[:error]
                logger.error "#{resp[:error][:code]}: #{resp[:error][:description]}"
                :abort
            else
                :success
            end
        end
    end
end
