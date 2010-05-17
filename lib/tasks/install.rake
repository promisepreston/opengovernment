# Configuration
require 'yaml'

desc "Install OpenGovernment under the current Rails env"
task :install => :environment do
  abcs = ActiveRecord::Base.configurations
  if abcs[Rails.env]["adapter"] != 'postgresql'
    raise "Sorry, OpenGovernment requires PostgreSQL"
  end

  puts "Creating #{Rails.env} database..."
  Rake::Task['db:create'].invoke

  Rake::Task['db:create:postgis'].invoke

  puts "Setting up the #{Rails.env} database"
  Rake::Task['db:migrate'].invoke

  # Core internal data
  Rake::Task['install:data'].invoke
end

namespace :db do
  namespace :create do
    desc "Install PostGIS tables"
    task :postgis => :environment do
      unless ActiveRecord::Base.connection.table_exists?("geometry_columns")
        puts "Installing PostGIS #{POSTGIS_VERSION} tables..."
        if `pg_config` =~ /SHAREDIR = (.*)/
          postgis_dir = File.join($1, 'contrib', "postgis-#{POSTGIS_VERSION}")
          unless File.exists? postgis_dir
            postgis_dir = File.join($1, 'contrib')
          end
        else
          raise "Could not find pg_config; please install PostgreSQL and PostGIS #{POSTGIS_VERSION}"
        end

        abcs = ActiveRecord::Base.configurations
        ENV['PGHOST']     = abcs[Rails.env]["host"] if abcs[Rails.env]["host"]
        ENV['PGPORT']     = abcs[Rails.env]["port"].to_s if abcs[Rails.env]["port"]
        ENV['PGPASSWORD'] = abcs[Rails.env]["password"].to_s if abcs[Rails.env]["password"]

        `createlang plpgsql -U "#{abcs[Rails.env]["username"]}" #{abcs[Rails.env]["database"]}`

        ['postgis.sql', 'spatial_ref_sys.sql'].each do |fn|
          `psql -U "#{abcs[Rails.env]["username"]}" -f #{File.join(postgis_dir, fn)} #{abcs[Rails.env]["database"]}`
        end
      end
    end
  end
end

namespace :install do
  desc "Download and insert all core data"
  task :data => :environment do
    # Fixtures
    Rake::Task['load:fixtures'].invoke
    Rake::Task['load:legislatures'].execute

    # Fetch all external data files
    Rake::Task['fetch:all'].invoke

    # Load external data
    Rake::Task['load:districts'].invoke

    # Note: People also imports addresses, so we don't invoke load:addresses
    Rake::Task['load:people'].invoke
    Rake::Task['load:bills'].invoke
  end
end

namespace :fetch do
  task :all do
    Rake::Task['fetch:districts'].invoke
  end

  task :setup => :environment do
    FileUtils.mkdir_p(DATA_DIR)
    Dir.chdir(DATA_DIR)
  end

  desc "Get the district SHP files for Congress and all active states"
  task :districts => :setup do
    OpenGov::Fetch::Districts.process
  end
end

namespace :load do
  # These tasks are listed in the order that we need the data to be inserted.
  task :fixtures => :environment do
    require 'active_record/fixtures'

    Dir.chdir(Rails.root)
    Fixtures.create_fixtures('lib/tasks/fixtures', 'legislatures')
    Fixtures.create_fixtures('lib/tasks/fixtures', 'chambers')
    Fixtures.create_fixtures('lib/tasks/fixtures', 'states')
    Fixtures.create_fixtures('lib/tasks/fixtures', 'sessions')

    # Force a reload of the DistrictType class, so we get the proper constants
    class_refresh("Legislature", "Chamber", "UpperChamber", "LowerChamber")
  end

  desc "Fetch and load legislatures from FiftyStates"
  task :legislatures => :environment do
    OpenGov::Load::Legislatures.import!
  end

  desc "Fetch and load addresses from VoteSmart"
  task :addresses => :environment do
    OpenGov::Load::Addresses.import!
  end

  desc "Fetch and load bills from FiftyStates"
  task :bills => :environment do
    OpenGov::Load::Bills.import!(:remote => false)
  end

  desc "Fetch and load people from FiftyStates, GovTrack and VoteSmart"
  task :people => :environment do
    OpenGov::Load::People.import!
    Dir.chdir(Rails.root)
    GovTrackImporter.new.import!
    Dir.chdir(Rails.root)
    OpenGov::Load::Addresses.import!
  end

  task :districts => :environment do
    Dir.glob(File.join(DISTRICTS_DIR, '*.shp')).each do |shpfile|
      OpenGov::Load::Districts::import!(shpfile)
    end

    class_refresh("District")
  end

  def class_refresh(*class_names)
    class_names.each do |klass_name|
      Object.class_eval do
        remove_const(klass_name) if const_defined?(klass_name)
      end
      load klass_name.tableize.singularize + ".rb"
    end
  end
end
