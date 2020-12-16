#!/bin/bash
#
# This file is part of rasdaman community.
#
# Rasdaman community is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Rasdaman community is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with rasdaman community.  If not, see <http://www.gnu.org/licenses/>.
#
# Copyright 2003-2009 Peter Baumann / rasdaman GmbH.
#
# For more information please see <http://www.rasdaman.org>
# or contact Peter Baumann via <baumann@rasdaman.com>.
#

./diskspace_probe.sh "`basename $0`" begin
BUILD_DIR=`pwd`
####

# NOTE: this script is executed with root
if [ -z "$USER_NAME" ] ; then
   USER_NAME="user"
fi
USER_HOME="/home/$USER_NAME"

RMANHOME=/opt/rasdaman

TOMCAT_WEBAPPS=/var/lib/tomcat9/webapps
TOMCAT_SVC=tomcat9

setup_rasdaman_repo()
{
  echo "Setup rasdaman package repository..."
  # add rasdaman public key
  local rasdaman_pkgs_url="http://download.rasdaman.org/packages"
  wget -q -O - "$rasdaman_pkgs_url/rasdaman.gpg" | apt-key add - \
    || { echo "Failed importing rasdaman GPG key."; return 1; }
  # add rasdaman repo
  local codename="$1"
  local release="$2"
  echo "deb [arch=amd64] $rasdaman_pkgs_url/deb $codename $release" > /etc/apt/sources.list.d/rasdaman.list
}

unpack_war_file()
{
  # unpacks $1.war into a directory $1, and removes $1.war
  local war_name="$1"
  local war_file="$war_name.war"
  pushd "$TOMCAT_WEBAPPS"
  if [ -f "$war_file" ]; then
    mkdir -p "$war_name"
    mv "$war_file" "$war_name"
    pushd "$war_name"
    unzip -q "$war_file" && rm -f "$war_file" # extract
    popd
  fi
  popd
}

delete_not_needed_files()
{
  # remove development stuff
  for f in lib include share/rasdaman/war share/rasdaman/raswct; do
    rm -rf $RMANHOME/$f
  done
  # remove development docs
  rm -rf $RMANHOME/share/rasdaman/doc/doc-*
  rm -rf $RMANHOME/share/rasdaman/doc/manuals
  # remove html docs (20MB), still remaining pdf docs (5MB)
  rm -rf $RMANHOME/share/rasdaman/doc/html
  # remove unneeded demo data, was inserted during installation
  rm -rf $RMANHOME/share/rasdaman/petascope/petascope_insertdemo_data
  # remove unneeded javascript code
  rm -rf $RMANHOME/share/rasdaman/www/rasql-web-console
  # strip executables
  for e in rascontrol rasql rasserver rasmgr; do
    strip --strip-unneeded $RMANHOME/bin/$e > /dev/null 2>&1 || true
  done

  # remove secore as it takes up 250 MB, use remote service
  sed -i 's|secore_urls=.*|secore_urls=https://ows.rasdaman.org/def,http://www.opengis.net/def|' \
      /opt/rasdaman/etc/petascope.properties
  rm -rf $TOMCAT_WEBAPPS/def.war $TOMCAT_WEBAPPS/def $TOMCAT_WEBAPPS/secoredb

  # remove cached deb packages
  apt-get -q clean
  apt-get -q autoclean
}

start_tomcat()
{
  # `service tomcat9 start` does not work when building the ISO,
  # so start tomcat manually, in order to import the demo data
  export CATALINA_HOME=/usr/share/tomcat9
  export CATALINA_BASE=/var/lib/tomcat9
  export CATALINA_TMPDIR=/tmp
  export JAVA_OPTS="-Djava.awt.headless=true -XX:+UseG1GC -Xmx2048m"

  /usr/libexec/tomcat9/tomcat-update-policy.sh
  nohup /usr/libexec/tomcat9/tomcat-start.sh > /tmp/tomcat-start-output.log &
}

stop_tomcat()
{
  pkill -f org.apache.catalina.startup.Bootstrap
}

install_rasdaman_pkg()
{
  echo "Install rasdaman package..."
  apt-get -qq update -y
  # automate any configuration update dialog
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get install -y $TOMCAT_SVC
  apt-get -o Dpkg::Options::="--force-confdef" install -y rasdaman \
    || { echo "Failed installing rasdaman package."; return 1; }

  # print the package installation log into the chroot-build.log
  echo "======================================================================="
  echo "Rasdaman command log start:"
  echo "======================================================================="
  cat /tmp/rasdaman.install.log
  echo "======================================================================="
  echo "Rasdaman command log end"
  echo "======================================================================="

  # make sure the rasdaman package is not removed by apt-get autoremove
  echo "rasdaman hold" | dpkg --set-selections
  # apt-mark manual rasdaman
  delete_not_needed_files
  # create log dir in case it's missing, otherwise starting rasdaman fails
  mkdir -p $RMANHOME/log

  # --------
  # need to unpack the war files (tomcat doesn't do it which causes issues)
  unpack_war_file rasdaman
  start_tomcat
  # --------

  echo
  echo "Rasdaman package installed successfully."
  echo
}

rasdaman_service()
{
  local cmd=$1
  sudo -u rasdaman /opt/rasdaman/bin/${cmd}_rasdaman.sh
  sleep 2
}

replace_rasdaman_user_with_system_user()
{
  local rasdaman_user=rasdaman
  local rasdaman_group=rasdaman
  echo "Replacing regular user '$rasdaman_user' with a system user..."

  # stop rasdaman service first, otherwise userdel will fail
  rasdaman_service stop

  userdel $rasdaman_user || { echo "Failed removing rasdaman user."; return 1; }
  groupdel $rasdaman_group > /dev/null 2>&1

  adduser --system --group --home /opt/rasdaman --no-create-home --shell /bin/bash $rasdaman_user
  chown -R $rasdaman_user:$rasdaman_group /opt/rasdaman
  # this directory is owned by an invalid uid after the user change, it can be just deleted
  rm -rf /tmp/rasdaman_*
  # add rasdaman user to tomcat group
  adduser $rasdaman_user tomcat
  # and user to rasdaman group
  adduser $USER_NAME $rasdaman_group

  rasdaman_service start
}

create_bin_starters()
{
  echo "Creating starting scripts..."
  cat > $RMANHOME/bin/rasdaman-start.sh <<EOF
#!/bin/bash
sudo service $TOMCAT_SVC start
sudo service rasdaman start
echo "Rasdaman was started."
EOF
  cat > $RMANHOME/bin/rasdaman-stop.sh <<EOF
#!/bin/bash
sudo service $TOMCAT_SVC stop
sudo service rasdaman stop
echo -e "Rasdaman stopped."
EOF
  chmod 755 $RMANHOME/bin/rasdaman-start.sh $RMANHOME/bin/rasdaman-stop.sh
}

create_desktop_applications()
{
  echo "Creating desktop icons..."
  for path in /usr/local/share/applications/ $USER_HOME/Desktop/; do
    mkdir -p $path
  cat > $path/start_rasdaman_server.desktop <<EOF
[Desktop Entry]
Type=Application
Encoding=UTF-8
Name=Start Rasdaman Server
Comment=Start Rasdaman Server
Categories=Application;Education;Geography;
Exec=$RMANHOME/bin/rasdaman-start.sh
Icon=gnome-globe
Terminal=true
StartupNotify=false
EOF
  cat > $path/stop_rasdaman_server.desktop <<EOF
[Desktop Entry]
Type=Application
Encoding=UTF-8
Name=Stop Rasdaman Server
Comment=Stop Rasdaman Server
Categories=Application;Education;Geography;
Exec=$RMANHOME/bin/rasdaman-stop.sh
Icon=gnome-globe
Terminal=true
StartupNotify=false
EOF
  cat > $path/rasdaman_earthlook_demo.desktop <<EOF
[Desktop Entry]
Type=Application
Encoding=UTF-8
Name=Rasdaman-Earthlook Demo
Comment=Rasdaman Demo and Tutorial
Categories=Application;Education;Geography;
Exec=firefox http://localhost/rasdaman-demo/
Icon=gnome-globe
Terminal=false
StartupNotify=false
EOF

    for f in $path/start_rasdaman_server.desktop $path/stop_rasdaman_server.desktop $path/rasdaman_earthlook_demo.desktop; do
      chown $USER_NAME: $f
      chmod 755 $f
    done
  done
  chown $USER_NAME: $USER_HOME/Desktop/
}

deploy_local_earthlook()
{
  echo "Deploying local earthlook..."
  local tmp_dir=/tmp/earthlook
  local data_url="http://kahlua.eecs.jacobs-university.de/~earthlook/osgeo/earthlook.tar.gz"

  mkdir -p "$tmp_dir"
  pushd "$tmp_dir" > /dev/null
  # download data
  wget -q "$data_url" -O earthlook.tar.gz
  # extract
  tar xzf earthlook.tar.gz
  rm -rf earthlook.tar.gz

  local rasdaman_demo_path="/var/www/html/rasdaman-demo"
  rm -rf "$rasdaman_demo_path"
  mkdir -p /var/www/html/

  # deploy
  mv "$tmp_dir" "$rasdaman_demo_path"
  chmod 755 "$rasdaman_demo_path"
  popd > /dev/null

  # Then import the selected coverages from Earthlook demo-data to local petascope
  # to be used for some demos which use queries on these small coverages.
  # (total size for Earthlook demo pages + data in tar file should be < 15 MB).
  "$rasdaman_demo_path/insert_demo_data.sh" 2>&1
}

add_rasdaman_path_to_bashrc()
{
  echo "Add rasdaman profile to the user's bashrc..."
  echo "source /etc/profile.d/rasdaman.sh" >> "$USER_HOME/.bashrc"
  # To find path to wcst_import.sh when deploying Earthlook
  source /etc/profile.d/rasdaman.sh
}

#
# Install and setup demos
#

setup_rasdaman_repo "focal" "nightly"
install_rasdaman_pkg

replace_rasdaman_user_with_system_user
create_bin_starters
create_desktop_applications
add_rasdaman_path_to_bashrc
deploy_local_earthlook

rasdaman_service stop
stop_tomcat



mv /etc/apt/sources.list.d/rasdaman.list /etc/apt/sources.list.d/rasdaman.list.disabled
apt-get -qq update -y

# echo "Rasdaman command log:"
# echo "==============================================="
# cat /tmp/rasdaman.install.log
# echo "==============================================="

####
"$BUILD_DIR"/diskspace_probe.sh "`basename $0`" end
