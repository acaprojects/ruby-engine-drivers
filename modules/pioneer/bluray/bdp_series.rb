module Pioneer; end
module Pioneer::Bluray; end


# Seems to support the protocol on ports 23 and 8102, 8102 being offical
# Requires "Quick Start" to be enabled in setup


class Pioneer::Bluray::BdpSeries
	include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


	def on_load
		on_update
	end
	
	def on_unload
	end
	
	def on_update
		defaults({
			delay: 100,
			delay_on_receive: 100,
			timeout: 8000
		})
		config({
			tokenize: true,
			delimiter: "\r\n"
		})
	end
	
	
	def connected
		do_poll
		@polling_timer = schedule.every('1m') do
            do_poll
        end
	end
	
	def disconnected
		@polling_timer.cancel unless @polling_timer.nil?
		@polling_timer = nil
	end

	
	COMMANDS = {
		power?: '?P',
		power_on: 'PN',
		power_off: 'PF',

		# Playback returns R on success
		play:  'PL',
		stop:  '99RJ',
		pause: 'ST',
		open:  'OP',
		close: 'CO',

		# These put the player into a paused state
		step_forward: 'SF',
		step_backwards: 'SR',

		# Return R when scanning
		# Must use stop_scan which pauses it
		# Then play can be used to play
		scan_forward: 'NF',
		scan_reverse: 'NR',
		stop_scan: 'SF',

		# Menu navigation
		top_menu: '/A181AFB4/RU',
		menu:     '/A181AFB9/RU',
		audio:    '/A181AFBE/RU',
		subtitle: '/A181AF36/RU',
		angle:    '/A181AFB5/RU',


		enter:  '/A181AFEF/RU',  # Select menu item (same as select)
		select: '/A181AFEF/RU',
		back:   '/A181AFF4/RU',  # Go back (same as exit)
		exit:   '/A181AF20/RU',


		next: '/A181AF3D/RU',
		previous: '/A181AF3E/RU',

		return: '/A181AFF4/RU', # Not sure what this does
		home:   'HM',			# Not sure this works


		# Both these return a number
		track: '?R',
		chapter: '?C',
		
		# Returns current second into track (playing and stopped)
		timecode: '?T',
		
		model_name: '?L', # Responds with 'BDP-450'
		firmware: '?Z',   # Responds with ''

		# These are useless
		dvd_status: '?V',
		bd_status: '?J',
		cd_status: '?K',
		# -----------------

		information: '?D'	# Responds with 100
	}


	#
	# Automatically creates a callable function for each command
	#	http://blog.jayfields.com/2007/10/ruby-defining-class-methods.html
	#	http://blog.jayfields.com/2008/02/ruby-dynamically-define-method.html
	#
	COMMANDS.each_key do |command|
		define_method command do |*args|
			options = args[0] || {}
			options[:name] = command
			do_send(COMMANDS[command], options)
		end
	end


	def power(state, options = {})
		state = is_affirmative?(state)
		options.merge!({
			delay: 5500   # Delay at least 5 seconds according to manual
		})
		if state == On
			do_send(COMMANDS[:power_on], options)
		else
			do_send(COMMANDS[:power_off], options)
		end
	end


	def eject
		self[:ejected] ? close : open
	end



	DIRECTIONS = {
		left: '/A187FFFF/RU',
		up: '/A184FFFF/RU',
		right: '/A186FFFF/RU',
		down: '/A185FFFF/RU'
	}
	def cursor(direction, options = {})
		val = DIRECTIONS[direction.to_sym]
		do_send(val, options)
	end



	protected

	
	ASCII = 'ASCII-8BIT'.freeze
	def do_send(cmd, options = {})
		cmd = "#{cmd}\r"
		send(cmd.encode(ASCII), options)
	end


	def do_poll
		power?(priority: 0) 
	end


	def set_state(code)
		self[:ejected] = code == 0
		self[:playing] = [4, 5, 8].include?(code)
		self[:paused] = code == 5 || code == 1
		self[:loading] = code == 2
		self[:scanning] = code == 8
	end


	def received(data, resolve, command)	
		logger.debug "Pioneer sent: #{data}"

		cmd = command ? command[:name] : :unknown

		case data[0].to_sym
		when :P
			# P00 powered on and tray open --confirmed
			# P01 powered on and stopped --confirmed
			# P02 powered and disk loading --confirmed
			#  
			# P04 powered and playing or in menu -- confirmed
			# P05 powered and paused -- confirmed
			#
			# P08 scanning -- confirmed
			# E04 when off
			code = data[1..-1].to_i
			self[:power] = true
			set_state(code)
		when :E
			case cmd
			when :power?
				self[:power] = false
				set_state(-1)
			end
		when :R
			case cmd
			when :play
				set_state(4)
			when :stop
				set_state(1)
			when :pause
				set_state(5)
			when :open
				set_state(0)
			when :close
				set_state(2)
			when :scan_forward, :scan_reverse
				set_state(8)
			when :power_off
				self[:power] = false
				set_state(-1)
			when :power_on
				power?
			end
		end

		return :success
	end
end
