module Transmitsms; end


class Transmitsms::Api
	include ::Orchestrator::Constants


	DECODE_OPTIONS = {
        symbolize_names: true
    }.freeze


	def on_load
		defaults({
            keepalive: false,
            inactivity_timeout: 1.5,  # seconds before closing the connection if no response
            connect_timeout: 2        # max seconds for the initial connection to the device
        })

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

		post('/send-sms.json', options) do |data, resolve|
			:success
		end
	end
end
