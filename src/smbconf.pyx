#+
# Copyright 2015 iXsystems, Inc.
# All rights reserved
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted providing that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
# IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#
#####################################################################


import enum
import cython
from libc.stdint cimport *
from libc.string cimport memcpy
cimport defs


cdef extern bint lp_load_global(const char *path)


class SambaConfigErrorCode(enum.IntEnum):
    OK = defs.SBC_ERR_OK
    NOT_IMPLEMENTED = defs.SBC_ERR_NOT_IMPLEMENTED
    NOT_SUPPORTED = defs.SBC_ERR_NOT_SUPPORTED
    UNKNOWN_FAILURE = defs.SBC_ERR_UNKNOWN_FAILURE
    NOMEM = defs.SBC_ERR_NOMEM
    INVALID_PARAM = defs.SBC_ERR_INVALID_PARAM
    BADFILE = defs.SBC_ERR_BADFILE
    NO_SUCH_SERVICE = defs.SBC_ERR_NO_SUCH_SERVICE
    IO_FAILURE = defs.SBC_ERR_IO_FAILURE
    CAN_NOT_COMPLETE = defs.SBC_ERR_CAN_NOT_COMPLETE
    NO_MORE_ITEMS = defs.SBC_ERR_NO_MORE_ITEMS
    FILE_EXISTS = defs.SBC_ERR_FILE_EXISTS
    ACCESS_DENIED = defs.SBC_ERR_ACCESS_DENIED


class SambaConfigException(Exception):
    def __init__(self, err):
        self.code = SambaConfigErrorCode(err)


cdef class SambaConfig(object):
    cdef defs.TALLOC_CTX *mem_ctx
    cdef defs.smbconf_ctx *conf
    cdef defs.smbconf_service **services
    cdef defs.smbconf_service *global_conf
    cdef uint32_t num_services

    def __init__(self, source):
        cdef defs.sbcErr err

        self.mem_ctx = <defs.TALLOC_CTX*>defs.talloc_new(NULL)
        err = defs.smbconf_init(self.mem_ctx, &self.conf, source)
        if err != defs.SBC_ERR_OK:
            raise SambaConfigException(err)

        self.refresh()

    def __getitem__(self, item):
        cdef defs.sbcErr err
        cdef char *result

        err = defs.smbconf_get_global_parameter(self.conf, self.mem_ctx, item, &result)
        if err != defs.SBC_ERR_OK:
            raise SambaConfigException(err)

        return result

    def __setitem__(self, key, value):
        cdef defs.sbcErr err

        err = defs.smbconf_set_global_parameter(self.conf, key, value)
        if err != defs.SBC_ERR_OK:
            raise SambaConfigException(err)

    def __delitem__(self, key):
        cdef defs.sbcErr err

        err = defs.smbconf_delete_global_parameter(self.conf, key)
        if err != defs.SBC_ERR_OK:
            raise SambaConfigException(err)

    def __contains__(self, item):
        try:
            _ = self[item]
        except SambaConfigException, err:
            if err.code == SambaConfigErrorCode.INVALID_PARAM:
                return False

            raise

        return True

    property shares:
        def __get__(self):
            cdef SambaSharesDict ret

            ret = SambaSharesDict.__new__(SambaSharesDict)
            ret.root = self
            return ret

    cdef defs.smbconf_service* service_by_name(self, name):
        for i in range(0, self.num_services):
            if self.services[i].name == str(name):
                return self.services[i]

        return NULL

    def refresh(self):
        cdef uint32_t num_shares
        cdef char **share_names
        cdef SambaShare share
        cdef defs.sbcErr err

        err = defs.smbconf_get_config(self.conf, self.mem_ctx, &self.num_services, &self.services)
        if err != defs.SBC_ERR_OK:
            raise SambaConfigException(err)

        if self.num_services > 0:
            self.global_conf = self.services[0]


cdef class SambaSharesDict(dict):
    cdef SambaConfig root

    def __repr__(self):
        return "{" + ', '.join(["'{0}': {1}".format(k, str(v)) for k, v in self.items()]) + "}"

    def __str__(self):
        return repr(self)

    def __getitem__(self, item):
        cdef SambaShare share

        for i in range(0, self.root.num_services):
            if self.root.services[i].name == item:
                share = SambaShare.__new__(SambaShare)
                share.root = self.root
                share.service = self.root.services[i]
                share.refresh()
                return share

        raise KeyError(item)

    def __setitem__(self, key, SambaShare value):
        cdef defs.sbcErr err

        if not isinstance(value, SambaShare):
            raise ValueError('Can only assign SambaShare instances')

        err = defs.smbconf_create_share(self.root.conf, defs.talloc_strdup(self.root.mem_ctx, key))
        if err != defs.SBC_ERR_OK:
            raise SambaConfigException(err)

        self.root.refresh()
        value.root = self.root
        value.service = self.root.service_by_name(key)
        value.save()

    def __delitem__(self, key):
        cdef defs.sbcErr err

        err = defs.smbconf_delete_share(self.root.conf, key)
        if err != defs.SBC_ERR_OK:
            raise SambaConfigException(err)

        self.root.refresh()

    def __iter__(self):
        return iter(self.keys())

    def __contains__(self, item):
        return item in self.keys()

    def keys(self):
        return filter(
            lambda n: n != 'global',
            [self.root.services[i].name for i in range(0, self.root.num_services)]
        )

    def values(self):
        cdef SambaShare share

        ret = []
        for i in range(0, self.root.num_services):
            if self.root.services[i].name == str('global'):
                continue

            share = SambaShare.__new__(SambaShare)
            share.root = self.root
            share.service = self.root.services[i]
            share.refresh()
            ret.append(share)

        return ret

    def items(self):
        return zip(self.keys(), self.values())

    def clear(self):
        for i in self.keys():
            del self[i]


cdef class SambaShare(dict):
    cdef public SambaConfig root
    cdef defs.smbconf_service *service

    def __repr__(self):
        return "<smbconf.SambaShare '{0}'>".format(self.name)

    def __str__(self):
        return repr(self)

    def refresh(self):
        self.clear()
        for i in range(0, self.service.num_params):
            self[self.service.param_names[i]] = self.service.param_values[i]

    def save(self):
        cdef defs.sbcErr err

        if not self.root:
            raise ValueError('Object is not attached to SambaConfig instance')

        for k, v in self.items():
            print 'name: {0}, k: {1}, v: {2}'.format(self.name, k, v)
            err = defs.smbconf_set_parameter(self.root.conf, self.name, k, v)
            if err != defs.SBC_ERR_OK:
                raise SambaConfigException(err)

        for i in range(0, self.service.num_params):
            if self.service.param_names[i] not in self:
                err = defs.smbconf_delete_parameter(self.root.conf, self.name, self.service.param_names[i])

    property name:
        def __get__(self):
            if self.service == NULL:
                return '<unnamed>'

            return self.service.name


cdef class SambaSession(object):
    cdef defs.sessionid session

    def __getstate__(self):
        return {
            'uid': self.uid,
            'username': self.username,
            'hostname': self.hostname,
            'netbios_name': self.netbios_name,
            'remote_machine': self.remote_machine,
            'id': self.id,
            'ip_address': self.ip_address,
            'protocol_version': self.protocol_version
        }

    property uid:
        def __get__(self):
            return self.session.uid

    property username:
        def __get__(self):
            return self.session.username

    property hostname:
        def __get__(self):
            return self.session.hostname

    property netbios_name:
        def __get__(self):
            return self.session.netbios_name

    property remote_machine:
        def __get__(self):
            return self.session.remote_machine

    property id:
        def __get__(self):
            return self.session.id_str

    property ip_address:
        def __get__(self):
            return self.session.ip_addr_str

    property protocol_version:
        def __get__(self):
            return self.session.protocol_ver


cdef class SambaConnection(object):
    cdef defs.connections_key key
    cdef defs.connections_data data

    def __getstate__(self):
        return {
            'uid': self.uid,
            'gid': self.gid,
            'service_name': self.service_name,
            'address': self.address,
            'machine': self.machine,
            'start': self.start
        }

    property uid:
        def __get__(self):
            return self.data.uid

    property gid:
        def __get__(self):
            return self.data.gid

    property service_name:
        def __get__(self):
            return self.data.servicename

    property address:
        def __get__(self):
            return self.data.addr

    property machine:
        def __get__(self):
            return self.data.machine

    property start:
        def __get__(self):
            return self.data.start


cdef int session_traverse_callback(const char *key, defs.sessionid *session, void *priv):
    cdef SambaSession ses

    obj = <object>priv
    ses = SambaSession.__new__(SambaSession)
    memcpy(&ses.session, session, cython.sizeof(defs.sessionid))
    obj.append(ses)
    return 0


cdef int connection_forall_callback(const defs.connections_key *key, const defs.connections_data *data, void *priv):
    cdef SambaConnection conn

    obj = <object>priv
    conn = SambaConnection.__new__(SambaConnection)
    memcpy(&conn.key, key, cython.sizeof(defs.connections_key))
    memcpy(&conn.data, data, cython.sizeof(defs.connections_data))
    obj.append(conn)
    return 0


def get_active_sessions():
    ret = []
    defs.sessionid_traverse_read(session_traverse_callback, <void*>ret)
    return ret


def get_active_users():
    ret = []
    defs.connections_forall_read(connection_forall_callback, <void*>ret)
    return ret


lp_load_global("") # XXX: Should be /usr/local/etc/smb4.conf?
