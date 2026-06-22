// Safari action-extension preprocessing: hands the current page's URL and
// title to the extension. Keep this bridge deliberately minimal: any exception
// before completion makes Safari expose an empty property-list provider.
var GetURL = function() {};
GetURL.prototype = {
    run: function(parameters) {
        parameters.completionFunction({ "URL": document.URL, "title": document.title });
    },
    finalize: function(parameters) {}
};
var ExtensionPreprocessingJS = new GetURL;
