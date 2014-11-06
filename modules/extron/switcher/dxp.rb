module Extron; end
module Extron::Switcher; end


# :title:Extron Digital Matrix Switchers
# NOTE:: Very similar to the XTP!! Update both
#
# Status information avaliable:
# -----------------------------
#
# (built in)
# connected
#
# (module defined)
# video_inputs
# video_outputs
# audio_inputs
# audio_outputs
#
# video1 => input (video)
# video2
# video3
# video1_muted => true
#
# audio1 => input
# audio1_muted => true
# 
#
# (Settings)
# password
#


class Extron::Switcher::Dxp
	include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


	def on_load
		#
		# Setup constants
		#
		defaults({
			:wait => false
		})
		config({
			:clear_queue_on_disconnect => true	# Clear the queue as we may need to send login
		})
	end

	def connected
		@polling_timer = schedule.every('2m') do
			logger.debug "-- Extron Maintaining Connection"
			send('Q', :priority => 0)	# Low priority poll to maintain connection
		end
	end

	def disconnected
		#
		# Disconnected may be called without calling connected
		#	Hence the check if timer is nil here
		#
		@polling_timer.cancel unless @polling_timer.nil?
		@polling_timer = nil
	end


	def direct(string)
		send(string, :wait => false)
	end


	#
	# No need to wait as commands can be chained
	#
	def switch(map)
		map.each do |input, outputs|
			input = input.to_s if input.is_a?(Symbol)
			input = input.to_i if input.is_a?(String)

			outputs = [outputs] unless outputs.is_a?(Array)
			command = ''
			outputs.each do |output|
				command += "#{input}*#{output}!"
			end
			send(command)
		end
	end

	def switch_video(map)
		map.each do |input, outputs|
			input = input.to_s if input.is_a?(Symbol)
			input = input.to_i if input.is_a?(String)
			
			
			outputs = [outputs] unless outputs.is_a?(Array)
			command = ''
			outputs.each do |output|
				command += "#{input}*#{output}%"
			end
			send(command)
		end
	end

	def switch_audio(map)
		map.each do |input, outputs|
			input = input.to_s if input.is_a?(Symbol)
			input = input.to_i if input.is_a?(String)
			
			outputs = [outputs] unless outputs.is_a?(Array)
			command = ''
			outputs.each do |output|
				command += "#{input}*#{output}$"
			end
			send(command)
		end
	end

	def mute_video(outputs)
		outputs = [outputs] unless outputs.is_a?(Array)
		command = ''
		outputs.each do |output|
			command += "#{output}*1B"
		end
		send(command)
	end

	def unmute_video(outputs)
		outputs = [outputs] unless outputs.is_a?(Array)
		command = ''
		outputs.each do |output|
			command += "#{output}*0B"
		end
		send(command)
	end

	def mute_audio(outputs)
		outputs = [outputs] unless outputs.is_a?(Array)
		command = ''
		outputs.each do |output|
			command += "#{output}*1Z"
		end
		send(command)
	end

	def unmute_audio(outputs)
		outputs = [outputs] unless outputs.is_a?(Array)
		command = ''
		outputs.each do |output|
			command += "#{output}*0Z"
		end
		send(command)
	end

	def set_preset(number)
		send("#{number},")
	end

	def recall_preset(number)
		send("#{number}.")
	end


	#def response_delimiter
	#	[0x0D, 0x0A]	# Used to interpret the end of a message
	#end


	#
	# Sends copyright information
	# Then sends password prompt
	#
	def received(data, resolve, command)
		logger.debug "Extron Matrix sent #{data}"

		if command.nil? && data =~ /Copyright/i
			pass = setting(:password)
			if pass.nil?
				device_ready
			else
				do_send(pass)		# Password set
			end
		elsif data =~ /Login/i
			device_ready
		elsif command.present? && command[:command] == :information
			data = data.split(' ')
			video = data[0][1..-1].split('X')
			self[:video_inputs] = video[0].to_i
			self[:video_outputs] = video[1].to_i

			audio = data[1][1..-1].split('X')
			self[:audio_inputs] = audio[0].to_i
			self[:audio_outputs] = audio[1].to_i
		else
			case data[0..1].to_sym
			when :Am	# Audio mute
				data = data[3..-1].split('*')
				self["audio#{data[0].to_i}_muted"] = data[1] == '1'
			when :Vm	# Video mute
				data = data[3..-1].split('*')
				self["video#{data[0].to_i}_muted"] = data[1] == '1'
			when :In	# Input to all outputs
				data = data[2..-1].split(' ')
				input = data[0].to_i
				if data[1] =~ /(All|RGB|Vid)/
					for i in 1..self[:video_outputs]
						self["video#{i}"] = input
					end
				end
				if data[1] =~ /(All|Aud)/
					for i in 1..self[:audio_outputs]
						self["audio#{i}"] = input
					end
				end
			when :Ou	# Output x to input y
				data = data[3..-1].split(' ')
				output = data[0].to_i
				input = data[1][2..-1].to_i
				if data[2] =~ /(All|RGB|Vid)/
					self["video#{output}"] = input
				end
				if data[2] =~ /(All|Aud)/
					self["audio#{output}"] = input
				end
			else
				if data == 'E22'	# Busy! We should retry this one
					command[:delay_on_receive] = 1 unless command.nil?
					return :failed
				end
			end
		end

		return :success
	end


	private


	def device_ready
		send("I", :wait => true, :command => :information)
		do_send("\e3CV", :wait => true)	# Verbose mode and tagged responses
	end

	def do_send(data, options = {})
		send(data << 0x0D, options)
	end
end

