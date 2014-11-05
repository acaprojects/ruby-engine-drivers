# encoding: US-ASCII

module Biamp; end

# TELNET port 23

class Biamp::Nexia
	include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
	
	def on_load
		self[:fader_min] = -36		# specifically for tonsley
		self[:fader_max] = 12

		# max +12
		# min -100

		config({
			tokenize: true,
			delimiter: /\xFF\xFE\x01|\r\n/
		})
	end
	
	def on_unload
	end
	
	def on_update
	end
	
	
	def connected
		send("\xFF\xFE\x01")	# Echo off
		do_send('GETD', 0, 'DEVID')
		
		@polling_timer = schedule.every('60s') do
			do_send('GETD', 0, 'DEVID')
		end
	end
	
	def disconnected
		@polling_timer.cancel unless @polling_timer.nil?
		@polling_timer = nil
	end
	
	
	def preset(number)
		#
		# Recall Device 0 Preset number 1001
		# Device Number will always be 0 for Preset strings
		# 1001 == minimum preset number
		#
		do_send('RECALL', 0, 'PRESET', number)
	end
	
	def fader(fader_id, level)
		# value range: -100 ~ 12
		do_send('SETD', self[:device_id], 'FDRLVL', fader_id, 1, level)
	end
	
	def mute(fader_id)
		do_send('SETD', self[:device_id], 'FDRMUTE', fader_id, 1, 1)
	end
	
	def unmute(fader_id)
		do_send('SETD', self[:device_id], 'FDRMUTE', fader_id, 1, 0)
	end

	def query_fader(fader_id)
		send("GET #{self[:device_id]} FDRLVL #{fader_id} 1 \n") do |data|
			if data == "-ERR"
				:abort
			else
				self[:"fader_#{fader_id}"] = data.to_i
				:success
			end
		end
	end

	def query_mute(fader_id)
		send("GET #{self[:device_id]} FDRMUTE #{fader_id} 1 \n") do |data|
			if data == "-ERR"
				:abort
			else
				self[:"fader_#{fader_id}_mute"] = data.to_i == 1
				:success
			end
		end
	end
	
	
	def received(data, resolve, command)
		data = data.split(' ')
		
		if data.length == 1
			if data[-1] == "-ERR"
				logger.debug "Nexia Invalid Command sent #{command[:data]}" if !!command
				return :abort
			end
			return :success	# data[-1] == "+OK" || data == ""	# Echo off
		end
		
		unless data[2].nil?
			case data[2].to_sym
			when :FDRLVL
				self[:"fader_#{data[3]}"] = data[-2].to_i
			when :FDRMUTE
				self[:"fader_#{data[3]}_mute"] = data[-2] == "1"
			when :DEVID
				self[:device_id] = data[-2].to_i
			end
		end
		
		return :success
	end
	
	
	
	private
	
	
	def do_send(*args)
		send("#{args.join(' ')}\n")
	end
end

