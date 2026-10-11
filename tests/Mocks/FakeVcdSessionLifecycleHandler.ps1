# Deterministic .NET HTTP handler for full-operation reauthentication tests.
# Sends no network requests and never returns genuine secrets.
if (-not ('VcdSessionLifecycleHandler' -as [type])) {
    Add-Type -ReferencedAssemblies @('System.Net.Http.dll') -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

public sealed class VcdSessionLifecycleHandler : HttpMessageHandler {
    public int LoginCount { get; private set; }
    public int FirewallReadCount { get; private set; }
    public int PageReadCount { get; private set; }
    public int ForbiddenCount { get; private set; }
    public string Mode { get; set; }
    public string SessionExpiry { get; set; }
    public bool AttestProviderSession { get; set; }
    public CancellationTokenSource CancelAtPage { get; set; }
    public List<string> Requests { get; private set; }
    public VcdSessionLifecycleHandler() { Mode = "OK"; Requests = new List<string>(); SessionExpiry = ""; }

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken cancellationToken) {
        cancellationToken.ThrowIfCancellationRequested();
        string path = req.RequestUri.AbsolutePath;
        Requests.Add(req.Method.Method + " " + path);
        if (req.Method.Method == "POST") {
            if (path != "/cloudapi/1.0.0/sessions" && path != "/cloudapi/1.0.0/sessions/provider")
                return Reply(HttpStatusCode.MethodNotAllowed, "{}");
            LoginCount++;
            if (Mode == "RenewalDenied" && LoginCount > 1)
                return Reply(HttpStatusCode.Unauthorized, "{\"password\":\"do-not-echo\"}");
            var login = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{}") };
            login.Headers.Add("X-VMWARE-VCLOUD-ACCESS-TOKEN", "unit-token-" + LoginCount);
            return Task.FromResult(login);
        }
        if (req.Method.Method != "GET") return Reply(HttpStatusCode.MethodNotAllowed, "{}");
        if (path == "/api/versions") return Reply(HttpStatusCode.OK, "<SupportedVersions><VersionInfo><Version>39.0</Version></VersionInfo></SupportedVersions>");
        if (req.Headers.Authorization == null || req.Headers.Authorization.Scheme != "Bearer")
            return Reply(HttpStatusCode.Unauthorized, "{}");
        if (path == "/cloudapi/1.0.0/sessions/current") {
            string org = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
            if (Mode == "ScopeChanges" && LoginCount > 1) org = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
            string expiry = SessionExpiry.Length == 0 ? "" : ",\"expirationDate\":\"" + SessionExpiry + "\"";
            string providerClaim = AttestProviderSession ? ",\"isProvider\":true" : "";
            return Reply(HttpStatusCode.OK, "{\"id\":\"urn:vcloud:session:" + LoginCount + "\",\"user\":\"engineer\",\"orgRef\":{\"id\":\"urn:vcloud:org:" + org + "\"}" + expiry + providerClaim + "}");
        }
        if (path.StartsWith("/cloudapi/1.0.0/edgeGateways/")) {
            return Reply(HttpStatusCode.OK, "{\"id\":\"urn:vcloud:gateway:55555555-5555-4555-8555-555555555555\",\"orgRef\":{\"id\":\"urn:vcloud:org:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\"}}");
        }
        if (path.StartsWith("/cloudapi/1.0.0/orgVdcNetworks/")) {
            return Reply(HttpStatusCode.OK, "{\"id\":\"urn:vcloud:network:44444444-4444-4444-8444-444444444444\",\"orgRef\":{\"id\":\"urn:vcloud:org:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\"}}");
        }
        if (path.Contains("/firewall/rules")) {
            FirewallReadCount++;
            return Reply(HttpStatusCode.OK, "{\"status\":\"REALIZED\",\"userDefinedRules\":[],\"systemRules\":[],\"defaultRules\":[]}");
        }
        if (path == "/cloudapi/1.0.0/manualIpReservations") {
            PageReadCount++;
            if (CancelAtPage != null) CancelAtPage.Cancel();
            if ((Mode == "ExpireOnce" || Mode == "RenewalDenied" || Mode == "ScopeChanges" || Mode == "Cancelled") && LoginCount == 1) {
                return Reply(HttpStatusCode.Unauthorized, "{\"token\":\"should-not-echo\"}");
            }
            if (Mode == "AlwaysUnauthorized") return Reply(HttpStatusCode.Unauthorized, "{}");
            if (Mode == "Forbidden") { ForbiddenCount++; return Reply(HttpStatusCode.Forbidden, "{}"); }
        }
        if (path == "/cloudapi/1.0.0/firewallGroups/summaries" || path == "/cloudapi/1.0.0/manualIpReservations")
            return Reply(HttpStatusCode.OK, "{\"page\":0,\"pageCount\":0,\"resultTotal\":0,\"values\":[]}");
        return Reply(HttpStatusCode.NotFound, "{}");
    }
    private static Task<HttpResponseMessage> Reply(HttpStatusCode code, string content) {
        return Task.FromResult(new HttpResponseMessage(code) { Content = new StringContent(content) });
    }
}
'@
}
