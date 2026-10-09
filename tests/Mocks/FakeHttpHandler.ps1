# Built-in .NET fake: all SendAsync requests complete in memory, never reaching a socket.
if (-not ('VcdMockHttpHandler' -as [type])) {
    Add-Type -ReferencedAssemblies @('System.Net.Http.dll') -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

public sealed class VcdMockHttpHandler : HttpMessageHandler {
    public int Count { get; private set; }
    public string LastMethod { get; private set; }
    public string LastPath { get; private set; }
    public string LastAuthScheme { get; private set; }
    public string LastAuthParameter { get; private set; }
    public string Mode { get; set; }
    public VcdMockHttpHandler() { Mode = "OK"; }

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct) {
        Count++;
        LastMethod = req.Method.Method;
        LastPath = req.RequestUri.AbsolutePath;
        LastAuthScheme = req.Headers.Authorization == null ? "" : req.Headers.Authorization.Scheme;
        LastAuthParameter = req.Headers.Authorization == null ? "" : req.Headers.Authorization.Parameter;
        HttpResponseMessage response;
        if (Mode == "Redirect") {
            response = new HttpResponseMessage(HttpStatusCode.Redirect);
            response.Headers.Location = new Uri("https://other.example.test/stolen");
        } else if (Mode == "Error") {
            response = new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);
            response.Content = new StringContent("sensitive server data should not be surfaced");
        } else if (LastPath == "/cloudapi/1.0.0/sessions" || LastPath == "/cloudapi/1.0.0/sessions/provider") {
            response = new HttpResponseMessage(HttpStatusCode.OK);
            response.Headers.Add("X-VMWARE-VCLOUD-ACCESS-TOKEN", "synthetic-token-123");
            response.Content = new StringContent("{\"id\":\"urn:vcloud:session:example\"}");
        } else if (LastPath == "/api/versions") {
            response = new HttpResponseMessage(HttpStatusCode.OK);
            response.Content = new StringContent("<SupportedVersions><VersionInfo><Version>39.0</Version></VersionInfo></SupportedVersions>");
        } else if (LastPath == "/cloudapi/1.0.0/sessions/current" && LastAuthScheme == "Bearer") {
            response = new HttpResponseMessage(HttpStatusCode.OK);
            response.Content = new StringContent("{\"id\":\"urn:vcloud:session:example\"}");
        } else {
            response = new HttpResponseMessage(HttpStatusCode.Unauthorized);
        }
        return Task.FromResult<HttpResponseMessage>(response);
    }
}
'@
}
