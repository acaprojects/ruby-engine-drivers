module Panasonic; end
module Panasonic::Projector; end


require 'digest/md5'

#
# Port: 1024
#
class Panasonic::Projector::PjLink
	include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

	def on_load
		# PJLink is slow
		defaults({
			timeout: 4000,
			delay_on_receive: 400
		})

		config({
			tokenize: true,
			delimiter: "\r",
			wait_ready: 'NTCONTROL'
		})

		@check_scheduled = false
		self[:power] = false
		self[:stable_state] = true  # Stable by default (allows manual on and off)
		self[:input_stable] = true
		
		# Meta data for inquiring interfaces
		self[:type] = :projector
	end

	def on_update
	end
	
	def connected
		@polling_timer = schedule.every('60s', method(:do_poll))
	end

	def disconnected
		self[:power] = false

		@polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
	end
	
	
	
	#
	# Power commands
	#
	def power(state, opt = nil)
		self[:stable_state] = false
		if is_affirmative?(state)
			self[:power_target] = On
			do_send(:POWR, 1, {:retries => 10, :name => :power})
			logger.debug "-- panasonic Proj, requested to power on"
			do_send('POWR', '?', :name => :power_state)
		else
			self[:power_target] = Off
			do_send(:POWR, 0, {:retries => 10, :name => :power})
			logger.debug "-- panasonic Proj, requested to power off"
			do_send('POWR', '?', :name => :power_state)
		end
	end

	def power?(options = {}, &block)
		options[:emit] = block if block_given?
		options[:name] = :power_state
		do_send(:POWR, options)
	end
	
	
	
	#
	# Input selection
	#
	INPUTS = {
		:hdmi => 31,
		:hdmi2 => 32,
		:digital => 33,
		:miracast => 52
	}
	INPUTS.merge!(INPUTS.invert)
	
	
	def switch_to(input)
		input = input.to_sym
		return unless INPUTS.has_key? input
		
		do_send(:INPT, INPUTS[input], {:retries => 10, :name => :inpt_source})
		do_send('INPT', '?', {:name => :inpt_query})
		logger.debug "-- panasonic LCD, requested to switch to: #{input}"
		
		self[:input] = input	# for a responsive UI
		self[:input_stable] = false
	end
	
	
	#
	# Mute Audio and Video
	#
	def mute
		logger.debug "-- panasonic Proj, requested to mute"
		do_send(:AVMT, 31, {:name => :video_mute})	# Audio + Video
	end

	def unmute
		logger.debug "-- panasonic Proj, requested to unmute"
		do_send(:AVMT, 30, {:name => :video_mute})
	end
	
	
	ERRORS = {
		:ERR1 => '1: Undefined control command'.freeze,
		:ERR2 => '2: Out of parameter range'.freeze,
		:ERR3 => '3: Busy state or no-acceptable period'.freeze,
		:ERR4 => '4: Timeout or no-acceptable period'.freeze,
		:ERR5 => '5: Wrong data length'.freeze,
		:ERRA => 'A: Password mismatch'.freeze
	}
	

	def received(data, resolve, command)		# Data is default received as a string
		logger.debug "panasonic Proj sent: #{data}"

		# This is the ready response 
		if data[0] == ' '
			@mode = data[1]
			if @mode == '1'
				@pass = "#{setting(:username) || 'admin1'}:#{setting(:password) || 'panasonic'}:#{data.strip.split(/\s+/)[-1]}"
				@pass = Digest::MD5.hexdigest(@pass)
			end

			:success

		# Error Response
		elsif data[0] == 'E'
			error = data.to_sym
			#self[:last_error] = ERRORS[error] (for error status query)

			# Check for busy or timeout
			if error == :ERR3 || error == :ERR4
				logger.warn "Panasonic Proj busy: #{self[:last_error]}"
				:retry
			else
				logger.error "Panasonic Proj error: #{self[:last_error]}"
				:abort
			end
			
		# Success Response
		else
			data = data[2..-1].split('=')

			if data[1] = 'OK'
				return :success
			else
				type = data[0][2..-1].to_sym
				response = data[1].to_i
				resolve.call(:success)

				case type
				when :POWR
					self[:power] = response >= 1 && response != 2
					self[:warming] = response == 3
					self[:cooling] = response == 2
					if response >= 2 && !@check_scheduled && !self[:stable_state]
						@check_scheduled = true
						schedule.in('20s') do
							@check_scheduled = false
							logger.debug "-- checking panasonic state"
							power?({:priority => 0}) do
								state = self[:power]
								if state != self[:power_target]
									if self[:power_target] || !self[:cooling]
										power(self[:power_target])
									end
								elsif self[:power_target] && self[:cooling]
									power(self[:power_target])
								else
									self[:stable_state] = true
									switch_to(self[:input]) if self[:power_target] == On && !self[:input].nil?
								end
							end
						end
					end
				when :INPT
					if INPUTS[response].present?
						self[:input] = INPUTS[response] if self[:input].nil?
						self[:actual_input] = INPUTS[response]
						if self[:input] == self[:actual_input]
							self[:input_stable] = true
						elsif self[:input_stable] == false
							schedule.in('5s') do
								logger.debug "-- forcing panasonic input"
								switch_to(self[:input]) if self[:input_stable] == false
							end
						end
					end
				when :AVMT
					self[:mute] = response == 31	# 10 == video mute off, 11 == video mute, 20 == audio mute off, 21 == audio mute, 30 == AV mute off
				when :LAMP
					self[:lamp] = data[1][0..-2].to_i
				end
			end
		end
	end

	
	
	protected
	
	
	def do_poll(*args)
		power?({:priority => 0}) do
			if self[:power]
				if self[:stable_state] == false && self[:power_target] == Off
					power(Off)
				else
					self[:stable_state] = true
					do_send(:INPT, {
						:name => :inpt_query,
						:priority => 0
					})
					do_send(:AVMT, {
						:name => :mute_query,
						:priority => 0
					})
					do_send(:LAMP, {
						:name => :lamp_query,
						:priority => 0
					})
				end
			elsif self[:stable_state] == false
				if self[:power_target] == On
					power(On)
				else
					self[:stable_state] = true
				end
			end
		end
	end

	def do_send(command, param = nil, options = {})
		if param.is_a? Hash
			options = param
			param = nil
		end

		if param.nil?
			pj = "#{command} ?"
		else
			pj = "#{command} #{param}"
		end

		if @mode == '0'
			send("00#{pj}\r", options)
		else
			send("#{@pass}00#{pj}\r", options)
		end
	end
end

