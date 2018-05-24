#!/bin/bash
set -e
set -o pipefail

# WARNING: make sure these files are not mounted
SLAPD_CONF="/etc/openldap/slapd.conf"
LDAP_CONF="/etc/openldap/ldap.conf"

# these files are mounted from the Admin Node
SLAPD_CONF_TEMPLATE=${SLAPD_CONF_TEMPLATE:-"/etc/openldap/slapd.conf.default"}
LDAP_CONF_TEMPLATE=${LDAP_CONF_TEMPLATE:-"/etc/openldap/ldap.conf.default"}

# When not limiting the open file descritors limit, the memory consumption of
# slapd is absurdly high. See https://github.com/docker/docker/issues/8231
ulimit -n 8192

mkdir -p /run/slapd

if [ -z "$SLAPD_PASSWORD_FILE" ]; then
    echo "SLAPD_PASSWORD_FILE must be set so the initial admin account is created"
    exit 1
fi

if [ -z "$SLAPD_DOMAIN" ]; then
    echo "SLAPD_DOMAIN must be set with the initial domain name"
    exit 1
fi

if [ -z "$SLAPD_ORGANIZATION" ]; then
    SLAPD_ORGANIZATION="SUSE"
fi

dc_string=""

IFS="."; declare -a dc_parts=($SLAPD_DOMAIN); unset IFS

for dc_part in "${dc_parts[@]}"; do
    dc_string="$dc_string,dc=$dc_part"
done

if [ -z "$SLAPD_ADMIN_USER" ] ; then
    SLAPD_ADMIN_USER="cn=admin,${dc_string:1}"
fi

IFS=","; declare -a admin_user_parts=($SLAPD_ADMIN_USER); unset IFS

base_string="BASE ${dc_string:1}"
suffix_string="suffix \"${dc_string:1}\""

password=`cat $SLAPD_PASSWORD_FILE`
password_hash=`slappasswd -s "${password}"`

echo "Copying configuration templates"
cp -f $SLAPD_CONF_TEMPLATE $SLAPD_CONF
cp -f $LDAP_CONF_TEMPLATE $LDAP_CONF

echo "Setting up $SLAPD_CONF configuration file"
sed -i "s|@SUFFIX@|${dc_string:1}|g" $SLAPD_CONF
sed -i "s|@ROOTDN@|${SLAPD_ADMIN_USER}|g" $SLAPD_CONF
sed -i "s|@ROOTPW@|${password_hash}|g" $SLAPD_CONF

if [ -n "$SLAPD_TLS_ENABLED" ]; then
    echo "Configuring TLS support in $SLAPD_CONF"
    cat >>$SLAPD_CONF <<EOF
TLSProtocolMin 3.1
TLSCipherSuite HIGH:!SSLv3:!SSLv2:!ADH
TLSCACertificateFile /etc/openldap/pki/ca.crt
TLSCertificateFile /etc/openldap/pki/openldap.crt
TLSCertificateKeyFile /etc/openldap/pki/openldap.pem
EOF

    LDAPS_URI="ldaps://"
fi

if [ ! -f /var/lib/ldap/data.mdb ]; then
    echo "Performing first start configuration..."

    # populate initial schema
    cat >/etc/openldap/slapd.ldif <<EOF
dn: cn=config
objectClass: olcGlobal
cn: config
#
#
# Define global ACLs to disable default read access.
#
olcArgsFile: /run/slapd.args
olcPidFile: /run/slapd.pid
#
EOF

    if [ -n "$SLAPD_TLS_ENABLED" ] ; then
        echo "Configuring TLS support in slapd.ldif"
        cat >>/etc/openldap/slapd.ldif <<EOF
olcTLSCipherSuite: HIGH:!SSLv3:!SSLv2:!ADH
olcTLSCACertificateFile: /etc/openldap/pki/ca.crt
olcTLSCertificateFile: /etc/openldap/pki/openldap.crt
olcTLSCertificateKeyFile: /etc/openldap/pki/openldap.pem

EOF
    fi

    cat >>/etc/openldap/slapd.ldif <<EOF
#
# Load dynamic backend modules:
#
dn: cn=module,cn=config
objectClass: olcModuleList
cn: module
olcModulepath: /usr/lib64/openldap
olcModuleload: back_mdb.la

dn: cn=schema,cn=config
objectClass: olcSchemaConfig
cn: schema

include: file:///etc/openldap/schema/core.ldif
include: file:///etc/openldap/schema/cosine.ldif
include: file:///etc/openldap/schema/ppolicy.ldif
include: file:///etc/openldap/schema/inetorgperson.ldif
include: file:///etc/openldap/schema/openldap.ldif
include: file:///etc/openldap/schema/nis.ldif
include: file:///etc/openldap/schema/misc.ldif

# Frontend settings
#
dn: olcDatabase=frontend,cn=config
objectClass: olcDatabaseConfig
objectClass: olcFrontendConfig
olcDatabase: frontend
#
# Sample global access control policy:
#	Root DSE: allow anyone to read it
#	Subschema (sub)entry DSE: allow anyone to read it
#	Other DSEs:
#		Allow self write access
#		Allow authenticated users read access
#		Allow anonymous users to authenticate
#
#olcAccess: to dn.base="" by * read
#olcAccess: to dn.base="cn=Subschema" by * read
#olcAccess: to *
#	by self write
#	by users read
#	by anonymous auth
#
# if no access controls are present, the default policy
# allows anyone and everyone to read anything but restricts
# updates to rootdn.  (e.g., "access to * by * read")
#
# rootdn can always read and write EVERYTHING!
#

dn: olcDatabase=mdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: mdb
olcSuffix: ${dc_string:1}
olcRootDN: ${SLAPD_ADMIN_USER}
olcRootPW: ${password_hash}
olcDbDirectory: /var/lib/ldap
olcDbIndex: default pres,eq
olcDbIndex: uid
olcDbIndex: cn,sn,mail pres,eq,sub
olcDbIndex: objectClass eq
olcSecurity: tls=1
EOF

    if [ -n "$SLAPD_TLS_ENABLED" ]; then
        cat >>/etc/openldap/slapd.ldif <<EOF
olcSecurity: tls=1
EOF
    fi

    echo "Configuring admin user access"
    slapadd -n 0 -F /etc/openldap/slapd.d -l /etc/openldap/slapd.ldif

    admin_cn=`echo ${admin_user_parts[0]} | sed 's|cn=||g'`

    cat >/tmp/ldif <<EOF
dn: ${dc_string:1}
objectClass: dcObject
objectClass: organization
dc: ${dc_parts[0]}
o: ${SLAPD_ORGANIZATION}
description: ${SLAPD_ORGANIZATION}

dn: ${SLAPD_ADMIN_USER}
objectclass: organizationalRole
cn: ${admin_cn}
EOF

    echo "Configuring initial database"
    slapadd -n 1 -F /etc/openldap/slapd.d -l /tmp/ldif
fi

echo "Starting $@"
exec "$@" -h "ldap:// ldapi:/// $LDAPS_URI"
