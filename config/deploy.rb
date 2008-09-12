set :domain, 'cezobal.com'
set :local, "#{`ifconfig | grep "192"`.match(/192\.168\.\d+\.\d+/)}"
set :application, "cezobal"
set :repository, "git@github.com:jeffrafter/cezobal.git"
set :keep_releases, 2
set :scm, :git
set :deploy_to, "/var/www/#{application}"
set :user, "deploy"
set :runner, "mongrel"
set :use_sudo, :false

role :app, "#{domain}"
role :web, "#{domain}"
role :db,  "#{domain}", :primary => true

# == CONFIG ====================================================================
namespace :init do
  namespace :config do
    desc "Create database.yml"
    task :database do
      if Capistrano::CLI.ui.ask("Create database configuration? (y/n): ") == 'y'
        set :db_name, Capistrano::CLI.ui.ask("database: ")
				set :db_user, Capistrano::CLI.ui.ask("database user: ")
				set :db_pass, Capistrano::CLI.password_prompt("database password: ")			
				database_configuration =<<-EOF
---
login: &login
  adapter: mysql
  host: localhost
  database: #{db_name}
  username: #{db_user}
  password: #{db_pass}

production:
  <<: *login

EOF
				run "mkdir -p #{shared_path}/config"
				put database_configuration, "#{shared_path}/config/database.yml"
		  end		
    end

    desc "Create mongrel_cluster.yml"
    task :mongrel do
      if Capistrano::CLI.ui.ask("Create mongrel configuration? (y/n): ") == 'y'
        mongrel_cluster_configuration = <<-EOF
--- 
user: #{runner}
cwd: #{current_path}
log_file: #{current_path}/log/mongrel.log
port: "18000"
environment: production
group: mongrel
address: 127.0.0.1
pid_file: #{current_path}/tmp/pids/mongrel.pid
servers: 1  
EOF
        run "mkdir -p #{shared_path}/config"
        put mongrel_cluster_configuration, "#{shared_path}/config/mongrel_cluster.yml"

        run "mkdir -p #{shared_path}/pids"
        run "mkdir -p #{shared_path}/log"
        run "touch #{shared_path}/log/production.log"
        sudo "chmod 0666 #{shared_path}/log/production.log"

        # Survive reboot
        mongrel_cluster_reboot_script = <<-EOF
#!/bin/bash
CONF_DIR=/etc/mongrel_cluster/
PID_DIR=#{current_path}/tmp/pids
USER=#{runner}
USER=mongrel
RETVAL=0

# Gracefully exit if the controller is missing.
which mongrel_cluster_ctl >/dev/null || exit 0

# Go no further if config directory is missing.
[ -d "$CONF_DIR" ] || exit 0

case "$1" in
    start)
      # Create pid directory
      mkdir -p $PID_DIR
      chown $USER:$USER $PID_DIR

      # remove stale pids
      rm -f $PID_DIR/mongrel.*

      mongrel_cluster_ctl start --clean -v -c $CONF_DIR
      RETVAL=$?
  ;;
    stop)
      mongrel_cluster_ctl stop --clean -v -c $CONF_DIR
      RETVAL=$?
  ;;
    restart)
      # remove stale pids
      rm -f $PID_DIR/mongrel.*

      mongrel_cluster_ctl restart --clean -v -c $CONF_DIR
      RETVAL=$?
  ;;
    status)                                                            
      mongrel_cluster_ctl status -v -c $CONF_DIR
      RETVAL=$?
  ;;
    *)
      echo "Usage: mongrel_cluster {start|stop|restart|status}"
      exit 1
  ;;
esac

exit $RETVAL
EOF
        run "mkdir -p #{shared_path}/scripts"
        put mongrel_cluster_reboot_script, "#{shared_path}/scripts/mongrel_cluster"
        sudo "cp #{shared_path}/scripts/mongrel_cluster /etc/init.d/mongrel_cluster"
        sudo "chmod +x /etc/init.d/mongrel_cluster"
        sudo "/usr/sbin/update-rc.d -f mongrel_cluster defaults"
        sudo "ln #{shared_path}/config/mongrel_cluster.yml /etc/mongrel_cluster/#{application}.yml"
      end  
    end
    
    desc "Create cron tasks for success testing, report caching and database backups"
    task :cron do
      if Capistrano::CLI.ui.ask("Create cron jobs? (y/n): ") == 'y'
     		cron_configuration =<<-EOF
# m h  dom mon dow   command
0 18 * * mon-fri mysqldump -u root cezobal > #{shared_path}/backup/cezobal.sql; /usr/local/bin/rsnapshot daily
0 18 * * sat /usr/local/bin/rsnapshot weekly
EOF
        run "mkdir -p #{shared_path}/backup"
        run "echo 'Current cron configuration'"
        run "crontab -l; echo ---"
        put cron_configuration, "#{shared_path}/scripts/cron"
        # Note this overwrites the cron configuration for the deploy user every time, if you have other crontabs you have to do more work
        run "cat #{shared_path}/scripts/cron | crontab -"
      end  
    end    

    desc "Symlink shared configurations to current"
    task :localize, :roles => [:app] do
      %w[mongrel_cluster.yml database.yml].each do |f|
        run "ln -nsf #{shared_path}/config/#{f} #{current_path}/config/#{f}"
      end
    end 		
  end  
end

# == NGINX =====================================================================
namespace :nginx do 
  desc "Start Nginx on the app server"
  task :start, :roles => :app do
    sudo "/etc/init.d/nginx start"
  end

  desc "Restart the Nginx processes on the app server by starting and stopping the cluster"
  task :restart , :roles => :app do
    sudo "/etc/init.d/nginx restart"
  end

  desc "Stop the Nginx processes on the app server"
  task :stop , :roles => :app do
    sudo "/etc/init.d/nginx stop"
  end

  desc "Setup the Nginx conf file from the example config"
  task :setup , :roles => :app do
    sudo "cp #{current_path}/config/nginx.conf.example /etc/nginx/nginx.conf"
  end
end

# == DEPLOY ======================================================================
namespace :deploy do
  desc "Start mongrel cluster"
  task :start do
    run  "cd #{current_path} && sudo mongrel_rails cluster::start"
  end
  
  desc "Stop mongrel cluster"
  task :stop do
    run  "cd #{current_path} && sudo mongrel_rails cluster::stop"
  end
  
  desc "Restart mongrel cluster"
  task :restart do
    run  "cd #{current_path} && sudo mongrel_rails cluster::restart"
  end  
end

# == TASKS =====================================================================
after "deploy", "deploy:cleanup"
after "deploy:migrations", "deploy:cleanup"
after "deploy:setup", "init:config:database"
after "deploy:setup", "init:config:mongrel"
after "deploy:setup", "init:config:cron"
after "deploy:symlink", "init:config:localize"

task :after_update_code do
  sudo "chown mongrel:mongrel #{release_path}/public -R" # Caching, in a public app this is not a good idea on closed systems it is okay
  sudo "chown mongrel:mongrel #{release_path}/tmp -R"
  sudo "chown mongrel:mongrel #{release_path}/log -R"
  sudo "chown mongrel:mongrel #{shared_path}/pids -R"
  sudo "chown mongrel:mongrel #{shared_path}/config -R"
end
