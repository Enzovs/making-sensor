require 'rubygems'
require 'bundler/setup'

require 'yaml'
require 'pg'
require 'json'
require 'mqtt'

# Global variables
$mqtt_client = nil
$db_conn = nil
$byebye = false

$stdout.sync = true

# Signal handler to handle a clean exit
Signal.trap("SIGTERM") {
  puts "Exiting"
  $byebye = true
}

# Release the MQTT connection
def closeMQTTConn(client)

  if ( !client.nil? )
    begin
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

  rescue MQTT::Exception,Errno::ECONNREFUSED,Errno::ENETUNREACH,SocketError => e
    $stderr.puts "ERROR: while connecting to MQTT server, class: #{e.class.name}, message: #{e.message}"

    if $byebye
      return nil
    end

    $stderr.puts "Sleep #{conf['mqtt']['retry']} seconds and retry"
    sleep conf['mqtt']['retry']
    retry
  end

  return client

end

# Release the DB connection
def closeDBConn(dbConn)
  if ( !dbConn.nil? )
    begin
      dbConn.finish()
    rescue Exception => e
      #ignore it
    end
  end
end

# Set up the DB connection
def makeDBConnection(conf, dbConn)

  if ( !dbConn.nil? && dbConn.status == PGconn::CONNECTION_OK)
    return dbConn
  end

  # trying anyway to release the connection just in case
  closeDBConn(dbConn)

  begin
    dbConn = PGconn.open(
      :host => conf['airqdb']['host'],
      :port => conf['airqdb']['port'],
      :options => conf['airqdb']['options'],
      :tty =>  conf['airqdb']['tty'],
      :dbname => conf['airqdb']['dbname'],
      :user => conf['airqdb']['user'],
      :password => conf['airqdb']['password']
    )

    dbConn.prepare("sensordata", "INSERT INTO #{conf['airqdb']['measurestable']} " +
      "(id, srv_ts, topic, rssi, temp, pm10, pm25, no2a, no2b, humidity, message) " +
      "VALUES ($1::bigint, $2::timestamp with time zone, $3::text, $4::smallint, $5::numeric, " +
      "$6::numeric, $7::numeric, $8::numeric, $9::numeric, $10::numeric, $11::text)")

  rescue PGError => e
    $stderr.puts "ERROR: while connecting to Postgres server, class: #{e.class.name}, message: #{e.message}"

    if $byebye
      return nil
    end

    $stderr.puts "Sleep #{conf['airqdb']['retry']} seconds and retry"
    sleep conf['airqdb']['retry']
    retry
  end

  return dbConn
end

# Close connections before exiting
def clean_up()
  puts "Closing MQTT and DB connections"
  closeMQTTConn($mqtt_client)
  closeDBConn($db_conn)
end


# here the main part starts
dir = File.dirname(File.expand_path(__FILE__))
ms_conf = YAML.load_file("#{dir}/../conf/makingsense.yaml")
puts ms_conf


mqtt_client = makeMQTTConnection(ms_conf,nil)
db_conn = makeDBConnection(ms_conf,nil)


while ! $byebye do
  begin
    begin
      # blocking call, not ideal if need to exit
      topic,msg = mqtt_client.get()
    rescue MQTT::Exception => e
      $stderr.puts "CRITICAL: while getting MQTT connection, class: #{e.class.name}, message: #{e.message}"
      if $byebye
        break
      end

      $stderr.puts "Sleep #{ms_conf['mqtt']['retry']} seconds and retry"
      sleep ms_conf['mqtt']['retry']
      mqtt_client = makeMQTTConnection(ms_conf,mqtt_client)
      retry
    end


    srv_ts = Time.now.strftime('%Y-%m-%d %H:%M:%S.%L%z')

      #msg.gsub!("pm2.5","pm25")

    begin
      msg_hash = JSON.parse(msg,symbolize_names: true)
    rescue JSON::JSONError => e
      $stderr.puts "ERROR: while processing sensor data: #{msg}, class: #{e.class.name}, message: #{e.message}"
      $stderr.puts "Save raw message with fake id"
      msg_hash = {}
      msg_hash[:i] = -1
      msg_hash[:message] = msg
    end

    puts "topic: #{topic}, msg: #{msg}, timestamp: #{srv_ts}, hash: " + msg_hash.to_s

    #id = topic.delete(ms_conf['mqtt']['topic'].delete('+'))

    begin

      parameters = nil
      # check for overflow

      if ( (! msg_hash["p2.5".to_sym].nil?) && msg_hash["p2.5".to_sym] == "ovf" )
        msg_hash["p2.5".to_sym] = -1
      end
      if ( (! msg_hash[:pm10].nil?) && msg_hash[:p10] == "ovf" )
        msg_hash[:p10] = -1
      end



      if (! msg_hash[:id].nil?)
        $stderr.puts "WARNING: Old format detected, translate to new format and save msg"
        msg_hash[:i] = msg_hash[:id]
      elsif (msg_hash[:i].nil?)
        $stderr.puts "WARNING: msg with no id: #{msg}"
        $stderr.puts "Save raw message with fake id"
        msg_hash[:i] = -1
        msg_hash[:message] = msg
      end

      parameters = [msg_hash[:i], srv_ts, topic, msg_hash[:r], msg_hash[:t], msg_hash[:p10],
            msg_hash["p2.5".to_sym], msg_hash[:a], msg_hash[:b], msg_hash[:h], msg_hash[:message]]

      res = db_conn.exec_prepared("sensordata",  parameters)

    rescue PG::NotNullViolation => e
      $stderr.puts "ERROR: while inserting message (PG::NotNullViolation): #{msg}, error: #{e.message}"
      $stderr.puts "Save raw message with fake id"
      msg_hash[:i] = -1
      msg_hash[:message] = msg
      $stderr.puts "Sleep #{ms_conf['airqdb']['retry']} seconds and retry"
      sleep ms_conf['airqdb']['retry']
      retry
    rescue PG::InvalidTextRepresentation => e
      $stderr.puts "ERROR: while inserting message (PG::InvalidTextRepresentation): #{msg}, error: #{e.message}"
      $stderr.puts "Save raw message with fake id"
      msg_hash[:i] = -1
      msg_hash[:message] = msg
      $stderr.puts "Sleep #{ms_conf['airqdb']['retry']} seconds and retry"
      sleep ms_conf['airqdb']['retry']
      retry
    rescue PG::CharacterNotInRepertoire => e
      $stderr.puts "ERROR: wrong encoding (PG::CharacterNotInRepertoire) for message: #{msg}, error: #{e.message}"
      $stderr.puts "Ignore msg"
    rescue PGError => e
      $stderr.puts "ERROR: while inserting into DB, class: #{e.class.name}, message: #{e.message}, payload: #{msg}"
      $stderr.puts "Ignore msg"
    end


  rescue Exception => e
    $stderr.puts "CRITICAL: Generic exception caught in process loop, class: #{e.class.name}, message: #{e.message}"
    $stderr.puts "Backtrace:\n\t#{e.backtrace.join("\n\t")}"
    $stderr.puts "Sensor data: topic: #{topic}, msg: #{msg}, timestamp: #{srv_ts}, hash: #{msg_hash.to_s}"

    if $byebye
      break
    end
    $stderr.puts "Sleep #{ms_conf['mqtt']['retry']} seconds and retry"
    sleep ms_conf['mqtt']['retry']
  end
end

at_exit do
  clean_up()
  puts "Program exited"
end
