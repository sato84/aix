# Author:: Jérôme Hurstel (<jerome.hurstel@atos.ne>) & Laurent Gay (<laurent.gay@atos.net>)
# Cookbook Name:: aix
# Provider:: suma
#
# Copyright:: 2016, Atos
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

property :desc, String, name_property: true
property :oslevel, String
property :location, String
property :targets, String
property :tmp_dir, String

class OhaiNimPluginNotFound < StandardError
end

class InvalidOsLevelProperty < StandardError
end

class InvalidLocationProperty < StandardError
end

class InvalidTargetsProperty < StandardError
end

class SumaError < StandardError
end

class SumaPreviewError < SumaError
end

class SumaDownloadError < SumaError
end

class SumaMetadataError < SumaError
end

class NimDefineError < StandardError
end

def check_ohai
  # get list of all NIM machines from Ohai
  begin
    all_machines=node.fetch('nim', {}).fetch('clients').keys
    Chef::Log.debug("Ohai client machine's list is #{all_machines}")
  rescue Exception => e
    raise OhaiNimPluginNotFound, "SUMA-SUMA-SUMA error: cannot find nim info from Ohai output"
  end
end

def compute_rq_type
  if property_is_set?(:oslevel)
    if oslevel =~ /^([0-9]{4}-[0-9]{2})(|-00|-00-0000)$/
      rq_type="TL"
    elsif oslevel =~ /^([0-9]{4}-[0-9]{2}-[0-9]{2})(|-[0-9]{4})$/
      rq_type="SP"
    elsif oslevel.empty? or oslevel.downcase.eql?("latest")
      rq_type="Latest"
    else
      raise InvalidOsLevelProperty, "SUMA-SUMA-SUMA error: oslevel is not recognized"
    end
  else
    rq_type="Latest"
  end
  rq_type
end

def compute_filter_ml (rq_type)

  selected_machines=Array.new
  # compute list of machines based on targets property
  if property_is_set?(:targets)
    if !targets.empty?
      targets.split(/[,\s]/).each do |machine|
        # expand wildcard
        machine.gsub!(/\*/,'.*?')
        node['nim']['clients'].keys.collect do |m|
          if m =~ /^#{machine}$/
            selected_machines.concat(m.split)
          end
        end
      end
      selected_machines=selected_machines.sort.uniq
    else
      selected_machines=node['nim']['clients'].keys.sort
      Chef::Log.warn("No targets specified, consider all nim standalone machines as targets")
    end
  else
    selected_machines=node['nim']['clients'].keys.sort
    Chef::Log.warn("No targets specified, consider all nim standalone machines as targets")
  end
  Chef::Log.debug("List of targets expanded to #{selected_machines}")

  # build machine-oslevel hash
  hash=Hash[selected_machines.collect do |m|
    begin
      client_oslevel=node['nim']['clients'].fetch(m).fetch('oslevel')
      Chef::Log.info("Obtained OS level for machine \'#{m}\': #{client_oslevel}")
      client_mllevel=client_oslevel.match(/^([0-9]{4}-[0-9]{2})(|-[0-9]{2}|-[0-9]{2}-[0-9]{4})$/)[1]
      [ m, client_mllevel ]
    rescue Exception => e
      Chef::Log.warn("Cannot find OS level for machine \'#{m}\' from Ohai output")
      [ m, nil ]
    end
  end ]
  hash.delete_if { |key,value| value.nil? } #or value.eql?(oslevel.match(/^([0-9]{4}-[0-9]{2})(|-[0-9]{2}|-[0-9]{2}-[0-9]{4})$/)[1]) }
  Chef::Log.debug("Hash table (machine/mllevel) built #{hash}")
  
  # discover FilterML level
  ary=hash.values.collect { |ml| ml.delete('-') }
  case rq_type
  when 'Latest'
    # check ml level of machines
    if ary.min[0..3].to_i < ary.max[0..3].to_i
	  Chef::Log.warn("Release level mismatch")
    end
    # find highest ML
    filter_ml=ary.max
  when 'SP', 'TL'
    # find lowest ML
    filter_ml=ary.min
  end
  if filter_ml.nil?
    raise InvalidTargetsProperty, "SUMA-SUMA-SUMA error: cannot discover filter ml based on the list of targets"
  else
    filter_ml.insert(4, '-')
  end
  filter_ml
end

def compute_rq_name (rq_type, filter_ml)
  if property_is_set?(:tmp_dir)
    if tmp_dir.empty?
      tmp_dir="/usr/sys/inst.images"
    end
  else
    tmp_dir="/usr/sys/inst.images"
  end
  if ::File.directory?("#{tmp_dir}")
    shell_out!("rm -rf #{tmp_dir}/*")
  else
    shell_out!("mkdir -p #{tmp_dir}")
  end

  case rq_type
  when 'Latest'
    # find latest SP for highest TL
    suma_metadata_s="/usr/sbin/suma -x -a DisplayName=\"#{desc}\" -a Action=Metadata -a RqType=#{rq_type} -a DLTarget=#{tmp_dir} -a FilterML=#{filter_ml}"
    so=shell_out(suma_metadata_s)
    if so.error?
      raise SumaMetadataError, "SUMA-SUMA-SUMA error: \"#{suma_metadata_s}\" returns \'#{so.stderr.chomp!}\'!\n#{so.stdout}"
    else
      Chef::Log.warn("Done suma metadata operation \"#{suma_metadata_s}\"")
      sps=shell_out("ls #{tmp_dir}/installp/ppc/*.install.tips.html").stdout.split
      Chef::Log.debug("sps=#{sps}")
      sps.collect! do |file|
        file.gsub!("install.tips.html","xml")
        text=::File.open(file).read
        text.match(/^<SP name="([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4})">$/)[1].delete('-')
      end
      rq_name=sps.max
	  unless rq_name.nil?
        rq_name.insert(4, '-')
        rq_name.insert(7, '-')
        rq_name.insert(10, '-')
      end
    end

  when 'TL'
    # pad with 0
    rq_name="#{oslevel.match(/^([0-9]{4}-[0-9]{2})(|-00|-00-0000)$/)[1]}-00-0000"

  when 'SP'
    if oslevel =~ /^([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4})$/
      rq_name=$1
    elsif oslevel =~ /^([0-9]{4}-[0-9]{2})-[0-9]{2}$/
      # find SP build number
      suma_metadata_s="/usr/sbin/suma -x -a DisplayName=\"#{desc}\" -a Action=Metadata -a RqType=Latest -a DLTarget=#{tmp_dir} -a FilterML=#{$1}"
      so=shell_out(suma_metadata_s)
      if so.error?
        raise SumaMetadataError, "SUMA-SUMA-SUMA error: \"#{suma_metadata_s}\" returns \'#{so.stderr.chomp!}\'\n#{so.stdout}"
      else
        Chef::Log.warn("Done suma metadata operation \"#{suma_metadata_s}\"")
        text=::File.open("#{tmp_dir}/installp/ppc/#{oslevel}.xml").read
        rq_name=text.match(/^<SP name="([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4})">$/)[1]
      end
    end
  end
  rq_name
end

def compute_lpp_source_name (rq_name)
  if property_is_set?(:location)
    location.chomp!('\/')
    if location.start_with?("/") or location.empty?
      # location is a directory
	  lpp_source="#{rq_name}-lpp_source"
    else
      # location is a lpp source
      lpp_source=location
    end
  else
    lpp_source="#{rq_name}-lpp_source"
  end
  lpp_source
end

def compute_dl_target (lpp_source)
  if property_is_set?(:location)
    location.chomp!('\/')
    if location.start_with?("/")
      dl_target="#{location}/#{lpp_source}"
      unless node['nim']['lpp_sources'].fetch(lpp_source, {}).fetch('location', nil) == nil
        Chef::Log.debug("Found lpp source \'#{lpp_source}\' location")
        unless node['nim']['lpp_sources'][lpp_source]['location'] =~ /^#{dl_target}/
          raise InvalidLocationProperty, "SUMA-SUMA-SUMA error: lpp source location mismatch"
        end
      end
    elsif location.empty?
      dl_target="/usr/sys/inst.images/#{lpp_source}"
    else
      begin
        dl_target=node['nim']['lpp_sources'].fetch(location).fetch('location')
        Chef::Log.debug("Discover \'#{location}\' lpp source's location: \'#{dl_target}\'")
      rescue Exception => e
        raise InvalidLocationProperty, "SUMA-SUMA-SUMA error: cannot find lpp_source \'#{location}\' from Ohai output"
      end
    end
  else
    dl_target="/usr/sys/inst.images/#{lpp_source}"
  end
  dl_target
end

load_current_value do
end

=begin
class Numeric
  def duration
    secs  = self.to_int
    mins  = secs / 60
    hours = mins / 60
    days  = hours / 24

    if days > 0
      "#{days} days and #{hours % 24} hours"
    elsif hours > 0
      "#{hours} hours and #{mins % 60} mins"
    elsif mins > 0
      "#{mins} mins #{secs % 60} secs"
    elsif secs >= 0
      "#{secs} secs"
    end
  end
end
=end

action :download do

  # inputs
  puts ""
  Chef::Log.debug("desc=\"#{desc}\"")
  Chef::Log.debug("oslevel=\"#{oslevel}\"")
  Chef::Log.debug("location=\"#{location}\"")
  Chef::Log.debug("targets=\"#{targets}\"")
  Chef::Log.debug("tmp_dir=\"#{tmp_dir}\"")

  check_ohai

  # compute suma request type based on oslevel property
  rq_type=compute_rq_type
  Chef::Log.debug("rq_type=#{rq_type}")

  # compute suma filter ml based on oslevel and targets property
  filter_ml=compute_filter_ml(rq_type)
  Chef::Log.debug("filter_ml=#{filter_ml}")

  # compute suma request name based on metadata info
  rq_name=compute_rq_name(rq_type, filter_ml)
  Chef::Log.debug("rq_name=#{rq_name}")

  # compute lpp source name based on request name
  lpp_source=compute_lpp_source_name(rq_name)
  Chef::Log.debug("lpp_source=#{lpp_source}")

  # compute dl target based on lpp source name
  dl_target=compute_dl_target(lpp_source)
  Chef::Log.debug("dl_target=#{dl_target}")

  # create directory
  unless ::File.directory?("#{dl_target}")
    mkdir_s="mkdir -p #{dl_target}"
	converge_by("create directory \'#{dl_target}\'") do
      shell_out!(mkdir_s)
	end
  end

  # suma preview
  suma_s="/usr/sbin/suma -x -a DisplayName=\"#{desc}\" -a RqType=#{rq_type} -a DLTarget=#{dl_target} -a FilterML=#{filter_ml}"
  case rq_type
  when 'SP'
    suma_s << " -a RqName=#{rq_name}"
  when 'TL'
    suma_s << " -a RqName=#{rq_name.match(/^([0-9]{4}-[0-9]{2})-00-0000$/)[1]}"
  end
  preview_dl=0
  preview_downloaded=0
  preview_failed=0
  preview_skipped=0
  suma_preview_s="#{suma_s} -a Action=Preview"
  Chef::Log.debug("SUMA preview operation: #{suma_preview_s}")
  so=shell_out(suma_preview_s, :environment => { "LANG" => "C" })
  if so.error?
    if so.stderr =~ /^0500-035 No fixes match your query.$/
      Chef::Log.info("SUMA-SUMA-SUMA error:\n#{so.stderr.chomp!}")
      Chef::Log.warn("Done suma preview operation \"#{suma_preview_s}\"")
    else
      raise SumaPreviewError, "SUMA-SUMA-SUMA error:\n#{so.stderr.chomp!}"
    end
  else
    Chef::Log.warn("Done suma preview operation \"#{suma_preview_s}\"")
    Chef::Log.info("#{so.stdout}")
    if so.stdout =~ /([0-9]+) downloaded.*?([0-9]+) failed.*?([0-9]+) skipped/m
      preview_downloaded=$1
	  preview_failed=$2
	  preview_skipped=$3
      Chef::Log.info("#{preview_downloaded} downloaded, #{preview_failed} failed, #{preview_skipped} skipped fixes")
      preview_dl=so.stdout.match(/Total bytes of updates downloaded: ([0-9]+)/)[1].to_f/1024/1024/1024
    end
  end

  unless preview_dl.to_f == 0
    succeeded=0
    failed=0
    skipped=0
    # suma download
	suma_download_s="#{suma_s} -a Action=Download"
    converge_by("suma download operation: \"#{suma_download_s}\"") do
      Chef::Log.warn("Start downloading #{preview_downloaded} fixes (~ #{preview_dl.to_f.round(2)} GB) to \'#{dl_target}\' directory.")
      #start=Time.now
      download_downloaded=0
      download_failed=0
      download_skipped=0
	  exit_status=Open3.popen3(suma_download_s) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        stdout.each_line do |line|
          if line =~ /^Download SUCCEEDED:/
            succeeded+=1
          elsif line =~ /^Download FAILED:/
            failed+=1
          elsif line =~ /^Download SKIPPED:/
            skipped+=1
          elsif line =~ /([0-9]+) downloaded/
            download_downloaded=$1
		  elsif line =~ /([0-9]+) failed/
            download_failed=$1
		  elsif line =~ /([0-9]+) skipped/
            download_skipped=$1
          elsif line =~ /(Total bytes of updates downloaded|Summary|Partition id|Filesystem size changed to)/
            # do nothing
          else
            puts "\n#{line}"
		  end
          #time_s=(Time.now-start).duration
		  print "\rSUCCEEDED: #{succeeded}/#{preview_downloaded}\tFAILED: #{failed}/#{preview_failed}\tSKIPPED: #{skipped}/#{preview_skipped}" #.  (Total time: #{time_s})."
		  stdout.flush
        end
		puts ""
        stdout.close
        stderr.each_line do |line|
          puts line
        end
		stderr.close
		wait_thr.value # Process::Status object returned.
      end
      Chef::Log.warn("Finish downloading #{succeeded} fixes.")
      unless exit_status.success?
        raise SumaDownloadError, "SUMA-SUMA-SUMA error: cannot downloading fixes"
      end
	  
    end

	# create nim lpp source
    if failed != 0 and node['nim']['lpp_sources'].fetch(lpp_source, nil) == nil
      nim_s="nim -o define -t lpp_source -a server=master -a location=#{dl_target} #{lpp_source}"
      Chef::Log.debug("NIM operation: #{nim_s}")
      converge_by("create nim lpp source \'#{lpp_source}}\'") do
        so=shell_out(nim_s)
        if so.error?
          raise NimDefineError, "SUMA-SUMA-SUMA error: cannot define lpp source.\n#{so.stderr.chomp!}"
        end
      end
    end

  end

end
