# Deterministic in-memory .NET handler for HTTP response/error contract tests.
# VCD_HTTP status tests must not touch DNS, TLS or real credentials.
if (-not ('Vcd106ResponseHandler' -as [type])) {
    Add-Type -ReferencedAssemblies @('System.Net.Http.dll') -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

public sealed class Vcd106ResponseHandler : HttpMessageHandler {
    public int StatusCode { get; set; }
    public string Payload { get; set; }
    public bool IncludeAccessToken { get; set; }
    public int Count { get; private set; }
    public string LastMethod { get; private set; }
    public string LastPath { get; private set; }
    public string LastAuthScheme { get; private set; }
    public string LastAccept { get; private set; }

    public Vcd106ResponseHandler() {
        StatusCode = 200;
        Payload = "{\"id\":\"urn:vcloud:session:synthetic\"}";
        IncludeAccessToken = false;
    }
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct) {
        ct.ThrowIfCancellationRequested();
        Count++;
        LastMethod = req.Method.Method;
        LastPath = req.RequestUri.AbsolutePath;
        LastAuthScheme = req.Headers.Authorization == null ? "" : req.Headers.Authorization.Scheme;
        LastAccept = req.Headers.Accept.ToString();
        HttpResponseMessage response = new HttpResponseMessage((HttpStatusCode)StatusCode);
        response.Content = new StringContent(Payload);
        if (IncludeAccessToken && req.Method == HttpMethod.Post) {
            response.Headers.TryAddWithoutValidation("X-VMWARE-VCLOUD-ACCESS-TOKEN", "synthetic-access-token");
        }
        if (StatusCode >= 300 && StatusCode < 400) {
            response.Headers.Location = new Uri("https://different.example.test/not-followed");
        }
        return Task.FromResult<HttpResponseMessage>(response);
    }
}
'@
}
