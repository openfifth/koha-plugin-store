$(window).on('load', function () {
  $("#overlay").fadeOut();
});

$(window).on("beforeunload", function () {
  $("#overlay").fadeIn();
});