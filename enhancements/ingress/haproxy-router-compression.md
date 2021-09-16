---
title: expose-compression-variables-in-haproxy
authors:
- "@candita"

reviewers:
- "@frobware"
- "@knobunc"
- "@Miciah"
- "@miheer"
- "@rfredette"
- "@deads2k"

approvers:
- "@Miciah"
- "@frobware"

creation-date: 2021-08-27

last-updated: 2021-08-27

status: implementable

see-also:

replaces:

superseded-by:

---

# Expose Compression Variables in HAProxy

## Release Signoff Checklist

- [x] Enhancement is `implementable`
- [ ] Design details are appropriately documented from clear requirements
- [ ] Test plan is defined
- [ ] Operational readiness criteria is defined
- [ ] Graduation criteria for dev preview, tech preview, GA
- [ ] User-facing documentation is created in [openshift-docs](https://github.com/openshift/openshift-docs/)

## Summary

This enhancement proposal extends the IngressController API to allow the cluster administrator
to configure HTTP traffic compression via HAProxy variables.  HTTP traffic compression increases the
performance of a website by reducing the size of data that is passed in HTTP transactions.  

## Motivation

Customers with large amounts of compressible routed traffic need the ability to gzip-compress
their ingress workloads, as described in feature request [NE-542](https://issues.redhat.com/browse/NE-542).
HAProxy in OpenShift 3.x exposed compression variables, so lack of access to the variables in OpenShift 4.x
is a migration blocker for customers that were using them in OpenShift 3.x.

The ability to configure compression was available in 3.11 and disappeared in 4.x. This proposal
reintroduces this ability to the extent of feature parity with 3.11.

### Goals

Enable the configuration of HTTP compression global defaults via the `IngressControllerSpec`, which will
expose the two environment variables `ROUTER_ENABLE_COMPRESSION` and `ROUTER_COMPRESSION_MIME`.

Enable HTTP compression on selected MIME types, be they wildcard (e.g. `text/*`, `application/*`, etc.) or
specific (e.g. `text/html`, `text/plain`, `text/css`, `application/json`, `image/svg+xml`, `font/eot`, etc.).

By exposing the environment variables, any HTTP request that terminates within HAProxy, with the header
**"Accept-Encoding: gzip"**, and with a MIME type that matches one of the configured MIME types will qualify to have
HTTP compression applied to its payload.  Note 1: this applies only to edge-terminated and reencrypt routes.  Passthrough
routes will not have compression applied.  Note 2: HAProxy can skip compression if it does not have the resources
available to provide compression at the moment when it is requested.

### Non-Goals

Though it is possible to provide the following options, they are not included in this proposal because they
were not requested in the RFE, which requests only feature parity with OCP 3.11.

* It is possible for us to validate the MIME types in order to preclude pointless compression on data that is already
  compressed.  This proposal specifically allows admins to choose their own MIME types but will provide guidance in the
  godoc on how to avoid pointless compression.  It is more likely that we would receive a request to change the allowed
  MIME types, than to receive a request for support on a HAProxy spending unnecessary resources on compression duties.

* HAProxy provides for the choice of compression algorithm (e.g. `identity`, `gzip`, `deflate`,
and `raw-deflate`).  This proposal covers only the `gzip` algorithm.

* HAProxy allows compression to be applied to the `listen`, `defaults`, `backend`, and `frontend`
sections of the configuration file.  This proposal covers only the global `defaults` section.

* HAProxy provides a `compression offload` configuration option that makes HAProxy remove the "Accept-Encoding"
header to prevent backend servers from compressing responses.  This forces all response compression to happen within
HAProxy, jeopardizing its performance.  This configuration option is not recommended, even by HAProxy guides, so it
is omitted from this proposal.

* HAProxy provides a performance tuning variable, `maxcomprate`, to set the maximum per-process input compression rate
  to the specified number of kilobytes per second.  It works in conjunction with `tune.comp.maxlevel` to rate-limit the
  compression level to save data bandwidth. Another, `maxcompcpuusage`, does the same to save limit CPU used on compression.
Neither variable is currently exposed, and both are omitted from this proposal.  (Other per-session performance tuning
variables like `maxconnrate`, which set the maximum per-process number of connections per second, and `maxsslrate`,
which sets the maximum per-process number of SSL sessions per second, are not exposed either.)

## Proposal

Currently, the haproxy.cfg contains the lines below in the `defaults` section, but the mechanism for setting the
environment variables is not exposed.
```go
defaults
...
{{- if isTrue (env "ROUTER_ENABLE_COMPRESSION") }}
  compression algo gzip
  compression type {{ env "ROUTER_COMPRESSION_MIME" "text/html text/plain text/css" }}
  {{- end }}
```

### Global HTTP Compression via IngressControllerSpec and environment variables

The proposed change to IngressControllerSpec exposes the HTTP compression configuration variables at the default level:
```go
type IngressControllerSpec struct {
...
    // httpCompression defines policy for HTTP traffic compression
    // 
    // The default value is no compression
    //
    // +optional
    HTTPCompression *HTTPCompressionPolicy `json:"httpCompression,omitempty"`
}
...
// httpCompressionPolicy turns on compression for the specified MIME types
//
// This field is optional, and its absence implies that compression should not be enabled
// globally in HAProxy.
//
// If httpCompressionPolicy exists, compression should be enabled only for the specified
// MIME types
type HTTPCompressionPolicy struct {

	// compressionEnabled defines the desired compression enablement
	// If true, compression is enabled for all MIME types specified in
	// CompressionMIMETypes.  If false, compression is disabled for any MIME type.
	//
	// +required
	// +kubebuilder:default=false
	CompressionEnabled bool `json:"compressionEnabled"`
	
	// compressionMIMETypes is a list of MIME types that should have compression applied.
	// At least one MIME type must be specified.
	//
	// Note: Not all MIME types benefit from compression, but HAProxy will still use resources
	// to try to compress if instructed to.  Generally speaking, text (html, css, js, etc.)
	// formats benefit from compression, but formats that are already compressed (pdf, image,
	// audio, video, etc.) benefit little in exchange for the time and cpu spent on compressing
	// again. See https://joehonton.medium.com/the-gzip-penalty-d31bd697f1a2
	//
	// +required
	// +kubebuilder:validation:MinItems=1
	CompressionMIMETypes []CompressionMIMEType `json:"compressionMIMETypes,omitempty"`
}

// CompressionMIMEType defines the format of a single MIME type
// E.g. "text/css; charset=utf-8", "text/html", "text/*", "image/svg+xml",
// "application/octet-stream", etc.
//
// +kubebuilder:validation:Pattern="[a-zA-Z0-9\\+-;= ]+/([a-zA-Z0-9\\\+-;= ]+|\\*)"
type CompressionMIMEType string
```

To set up the IngressControllerSpec to use HTTP compression for a set of specific MIME types, the configuration
might resemble:
```yaml
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: default
  namespace: openshift-ingress-operator
spec:
  httpCompression:
    compressionEnabled: true
    compressionMIMETypes:
    - "text/html"
    - "text/css; charset=utf-8"
    - "application/json"
```

### User Stories

#### As a cluster administrator, I need to enable gzip HTTP compression globally for a selection of MIME types

Select the necessary MIME types and edit the IngressController spec as shown:

```yaml
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: default
  namespace: openshift-ingress-operator
spec:
  httpCompression:
    compressionEnabled: true
    compressionMIMETypes:
    - "text/html"
    - ...
```

Tips for troubleshooting:
- check response headers for evidence of compression: **"Content-Encoding: gzip"**
- the content of the response should be smaller than what was sent by the application

### Implementation Details/Notes/Constraints

Compression is not always applied even if it is requested.  If a backend server supports HTTP compression, the
compression directives will become no-op: HAProxy will see the compressed response and will not compress again. If a
backend server does not support HTTP compression, and the header "Accept-Encoding" exists in the request, HAProxy will
compress the matching response.  Also, if the HAProxy doesn't have enough resources to perform compression, it may skip
the compression in order to stay functional.  Process-level directives exist to tune this behavior: `maxcomprate`,
`maxcompcpuusage`, and `tune.comp.maxlevel` as described in the
[HAProxy compression documentation](https://www.haproxy.com/documentation/hapee/latest/load-balancing/compression/),
but these are not in scope of this proposal.

### Risks and Mitigations

Overuse of compression can cause the HAProxy to devote more resources to compression than to other operations,
compromising its operation.  We do not have any evidence that this will occur, and give detailed notes on use of
necessary MIME types to mitigate pointless compression and overuse of compression.  Should this become a problem
in the future, we can add default values for the process-level directives mentioned above (`maxcomprate`,
`maxcompcpuusage`, and `tune.comp.maxlevel`)  The team consensus is that adding more tunable knobs at this stage is
premature and could cause more issues than it mitigates.

We considered disallowing wildcard MIME types (e.g. `application/*`), so that explicit choices must be made on which
MIME types are subject to compression, but as mentioned, it is more likely that any MIME type omission would generate
a new RFE than for there to be a support issue caused by excessive pointless compression.

Security and UX are not a part of this proposal, but API team members will be invited to comment.

## Design Details
Design details are covered in the Proposal section, but some additional detailed notes from the
[HAProxy compression documentation](https://www.haproxy.com/documentation/hapee/latest/load-balancing/compression/)
are listed below.

### Compression types
MIME types to apply compression to,  are read from the Content-Type response header field. If a MIME type is not set,
HAProxy tries to compress all responses that are not compressed by the server.  Therefore, at least one MIME type is
required in the `HTTPCompressionPolicy`.  We consider the fact that cluster admins may want to create and use their
own MIME type, but the allowed set of characters is defined in a kubebuilder validation
pattern  of `"[a-zA-Z0-9\\+-;= ]+/([a-zA-Z0-9\\\+-;= ]+|\\*)"`, to allow a token of alphanumeric plus "_-;= " followed
by "/" followed by another alphanumeric token of the same pattern, or "*", the wildcard character.

### Open Questions
Is the MIME type pattern still too strict?  I reviewed the `mime` golang package at https://golang.org/src/mime/type.go,
`builtinTypesLower` map, but if we intend to allow any custom MIME type, perhaps a wider net should be cast, as in
https://golang.org/src/mime/grammar.go.

### Test Plan
- Unit tests will validate
  - that at least one HTTP compression MIME type exists and any listed MIME types adhere to the
  correct pattern
  - that the HTTP compression directive appears in the `defaults` section of the HAProxy template
  when it is enabled and properly configured on the IngressController spec
  - that a downgrade to version 4.9 (or version previous to feature implementation version) will not retain the
  compression configuration of 4.10 (the environment variables should no longer be exposed)
- E2e tests will validate
  - that the IngressController spec accepts and enables compression in the `defaults` section of
  the generated haproxy.cfg
  - that only requested MIME types receive compression

Note that HAProxy Enterprise **disables** HTTP compression when:
- The request does not advertise a supported compression algorithm in the "Accept-Encoding" header
- The response message is not HTTP/1.1 or above
- The HTTP status code is not one of 200, 201, 202 or 203
- The response contains neither a "Content-Length" header, nor a "Transfer-Encoding" header whose last value is `chunked`
- The response contains a "Content-Type" header whose first value starts with `multipart`
- The response contains a "Cache-Control" header with a value of `no-transform`
- The response contains a "Content-Encoding" header, indicating that the response is already compressed (see `compression offload`)
- The response contains an invalid "ETag" header or multiple "Etag" headers

### Graduation Criteria

This feature will be immediately available in release 4.10, and will not have a dev or tech preview.

#### Dev Preview -> Tech Preview
n/a

#### Tech Preview -> GA
n/a

#### Removing a deprecated feature

- Announce deprecation and support policy of the existing feature
- Deprecate the feature

### Upgrade / Downgrade Strategy

An upgrade from a previous installation that had the compression directives exposed, will need to change to use the
IngressController spec.

If a cluster administrator applied any of the compression configuration options
in 4.10, then downgraded to 4.9, the compression configuration settings should no longer be in effect for the default
IngressController/HAProxy.

### Version Skew Strategy
n/a

## Implementation History
n/a

## Drawbacks

By implementing this proposal we are giving the user tools that could threaten the operation of HAProxy.
Improper configuration of the MIME types or general over-use of compression could allow the HAProxy to
dedicate more processing time to compression than to its main duties of routing and traffic management.

## Alternatives
n/a
