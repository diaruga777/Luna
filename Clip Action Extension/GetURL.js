// Safari action-extension preprocessing: hands the current page's URL and
// title to the extension. Without this, a `com.apple.ui-services` action
// extension receives no usable web URL from Safari and appears to do nothing.
var GetURL = function() {};
GetURL.prototype = {
    run: function(parameters) {
        parameters.completionFunction({ "URL": document.URL, "title": document.title });
    },
    finalize: function(parameters) {}
};
var ExtensionPreprocessingJS = new GetURL;
