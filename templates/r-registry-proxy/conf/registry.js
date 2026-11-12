var PROJECT = 'slc-rdt';
// Temporary: job containers cannot resolve r.slc.net (no DNS record, only /etc/hosts
// on hosts and dind), so clients are sent to the token endpoint by IP. Replace
// with https://r.slc.net/service/token once DNS has a record for it.
var REALM = 'http://10.22.64.191:8002/service/token';

function tokenArgs(r) {
    var args = r.variables.args || '';
    return args.replace(/repository(%3A|:)([^%&:\/+]+)(?=%3A|:)/gi, 'repository$1' + PROJECT + '%2F$2');
}

function v2Args(r) {
    var args = r.variables.args || '';
    return args.replace(/(^|&)from=([^%&\/]+)(?=&|$)/g, '$1from=' + PROJECT + '%2F$2');
}

function challenge(r) {
    var header = r.headersOut['WWW-Authenticate'];
    if (header && header.indexOf('Bearer ') === 0) {
        r.headersOut['WWW-Authenticate'] = header.replace(/realm="[^"]*"/, 'realm="' + REALM + '"');
    }
}

export default { tokenArgs, v2Args, challenge };
