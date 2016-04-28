require 'rubygems'
require 'mqtt'
require 'yaml'
require 'pg'
require 'json'


# Global variables
$mqtt_client = nil
$db_conn = nil
$byebye = false

# Release the MQTT connection
def closeMQTTConn(client)

  if ( !client.nil? )
    begin
    # trying anyway to release the client just in case
      client.disconnect(send_msg = false)
    rescue Exception => e
    #ignore it
    end
  end
end

# Set up the MQTT connection
def makeMQTTConnection(conf, client)

  if ( !client.nil? && client.connected?)
    return client
  end

  # trying anyway to release the client just in case
  closeMQTTConn(client)

  is_on = false

  while ! is_on do
    begin
      client = MQTT::Client.connect(
        :host => conf['mqtt']['host'],
        :port => conf['mqtt']['port'],
        :ssl => conf['mqtt']['ssl'],
        :clean_session => conf['mqtt']['clean_session'],
        :client_id => conf['mqtt']['client_id'],
        :username => conf['mqtt']['username'],
        :password => conf['mqtt']['password']
      )
      client.subscribe([conf['mqtt']['topic'],conf['mqtt']['QoS']])

      is_on = true

    rescue MQTT::Exception,Errno::ECONNREFUSED,Errno::ENETUNREACH,SocketError => e
      $stderr.puts "Error in connecting to MQTT server, class: #{e.class.name}, message: #{e.message}, sleep and retry"
      sleep conf['mqtt']['retry']
    end
  end
  return client
end

# Release the DB connection
def closeDBConn(conn)
  if ( !conn.nil? )
    begin
      conn.finish()
    rescue Exception => e
      #ignore it
    end
  end
end

# Set up the DB connection
def makeDBConnection(conf, conn)

  if ( !conn.nil? && conn.status == PGconn::CONNECTION_OK)
    return conn
  end

  # trying anyway to release the connection just in case
  closeDBConn(conn)

  is_on = false

  while ! is_on do
    begin

      conn = PGconn.open(
        :host => conf['airqdb']['host'],
        :port => conf['airqdb']['port'],
        :options => conf['airqdb']['options'],
        :tty =>  conf['airqdb']['tty'],
        :dbname => conf['airqdb']['dbname'],
        :user => conf['airqdb']['user'],
        :password => conf['airqdb']['password']
      )

      conn.prepare("sensordata", "INSERT INTO #{conf['airqdb']['measurestable']} (id, srv_ts, topic, rssi, temp, pm10, pm25, no2a, no2b, message) " +
                  "VALUES ($1::bigint, $2::timestamp with time zone, $3::text, $4::smallint, $5::numeric, $6::numeric, $7::numeric, $8::numeric, $9::numeric, $10::text)")

      is_on = true

    rescue PGError => e
      $stderr.puts "Error in connecting to Postgres server, class: #{e.class.name}, message: #{e.message}, sleep and retry"
      sleep conf['airqdb']['retry']
    end
  end
  return conn
end

# Close connections before exiting
def clean_up()
  puts "Closing MQTT and DB connections"
  closeMQTTConn($mqtt_client)
  closeDBConn($db_conn)
end

# Signal handler to handle a clean exit
Signal.trap("SIGTERM") {
  puts "Exiting"
  $byebye = true
  }

# here the main part starts
dir = File.dirname(File.expand_path(__FILE__))
ms_conf = YAML.load_file("#{dir}/../conf/makingsense.yaml")
puts ms_conf


mqtt_client = makeMQTTConnection(ms_conf,nil)
db_conn = makeDBConnection(ms_conf,nil)


while ! $byebye do
  begin
    done = false
    while ! done
      begin
        # blocking call, not ideal if need to exit
        topic,msg = mqtt_client.get()
        done = true
      rescue MQTT::Exception => e
        $stderr.puts "Error with the MQTT connection, class: #{e.class.name}, message: #{e.message}"
        $stderr.puts "Sleep and retry"
        sleep ms_conf['mqtt']['retry']
        mqtt_client = makeMQTTConnection(ms_conf,mqtt_client)
      end
    end

    srv_ts = Time.now.strftime('%Y-%m-%d %H:%M:%S.%L%z')

      #msg.gsub!("pm2.5","pm25")

    begin
      msg_hash = JSON.parse(msg,symbolize_names: true)
    rescue JSON::JSONError => e
      $stderr.puts "Error processing sensor data: #{msg}, class: #{e.class.name}, message: #{e.message}"
      $stderr.puts "Skip message and continue"
      next
    end

    puts "topic: #{topic}, msg: #{msg}, timestamp: #{srv_ts}, hash: " + msg_hash.to_s

    #id = topic.delete(ms_conf['mqtt']['topic'].delete('+'))

    done = false
    while ! done
      begin
        res = db_conn.exec_prepared("sensordata",[msg_hash[:id], srv_ts, topic, msg_hash[:rssi], msg_hash[:temp], msg_hash[:pm10],
              msg_hash["pm2.5".to_sym], msg_hash[:no2a], msg_hash[:no2b], msg_hash[:message]])
        done = true
      rescue PG::NotNullViolation => e
        $stderr.puts "Error inserting message: #{msg}, error: #{e.message}"
        $stderr.puts "Ignore message"
      rescue PGError => e
        $stderr.puts "Error with the DB connection, class: #{e.class.name}, message: #{e.message}"
        $stderr.puts "Sleep and retry"
        sleep ms_conf['airqdb']['retry']
        db_conn = makeDBConnection(ms_conf,db_conn)
      end
    end

  rescue Exception => e
    $stderr.puts "Error in process loop, class: #{e.class.name}, message: #{e.message}"
    $stderr.puts "Sensor data: topic: #{topic}, msg: #{msg}, timestamp: #{srv_ts}, hash: #{msg_hash.to_s}"
    $stderr.puts "Sleep and continue"
    sleep ms_conf['mqtt']['retry']
  end
end

at_exit do
  clean_up()
  puts "Program exited"
end
