$(window).on("pageshow", function () {
  $("#overlay").fadeOut();
});

$(window).on("beforeunload", function () {
  $("#overlay").fadeIn();
});