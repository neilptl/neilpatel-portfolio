const MOVIES_URL = "./movie-explorer/movies.json";
const CONFIG_URL = "./movie-explorer/recommender-config.json";

const state = {
  movies: [],
  config: null,
  selectedMovieId: null,
};

const elements = {
  status: document.getElementById("movie-dashboard-status"),
  movieSelect: document.getElementById("movie-select"),
  genreFilter: document.getElementById("genre-filter"),
  decadeFilter: document.getElementById("decade-filter"),
  runtimeFilter: document.getElementById("runtime-filter"),
  recommendButton: document.getElementById("recommend-button"),
  randomButton: document.getElementById("random-button"),
  summaryMovieCount: document.getElementById("summary-movie-count"),
  summaryGenreCount: document.getElementById("summary-genre-count"),
  summaryYearRange: document.getElementById("summary-year-range"),
  summaryRuntime: document.getElementById("summary-runtime"),
  selectedMoviePanel: document.getElementById("selected-movie-panel"),
  recommendationsGrid: document.getElementById("recommendations-grid"),
  similarityChart: document.getElementById("similarity-chart"),
  genreChart: document.getElementById("genre-chart"),
  yearChart: document.getElementById("year-chart"),
  comparisonTableBody: document.getElementById("comparison-table-body"),
};

function average(values) {
  if (!values.length) {
    return 0;
  }

  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function intersection(left, right) {
  const rightSet = new Set(right);
  return left.filter((item) => rightSet.has(item));
}

function tokenizePlot(plot, stopwords) {
  return [...new Set(
    String(plot)
      .toLowerCase()
      .replace(/[^a-z0-9\s]/g, " ")
      .split(/\s+/)
      .filter((word) => word.length >= 4 && !stopwords.has(word))
  )];
}

function normalizeMovie(movie, stopwords) {
  const actors = String(movie.actors || "")
    .split(",")
    .map((actor) => actor.trim())
    .filter(Boolean);

  const year = Number(movie.year) || 0;
  const runtime = Number(movie.runtime) || 0;
  const genres = Array.isArray(movie.genres) ? movie.genres.filter(Boolean) : [];

  return {
    id: Number(movie.id),
    title: movie.title,
    year,
    runtime,
    genres,
    director: String(movie.director || "").trim(),
    actors,
    plot: String(movie.plot || "").trim(),
    posterUrl: String(movie.posterUrl || "").trim(),
    decade: year ? Math.floor(year / 10) * 10 : null,
    keywords: tokenizePlot(movie.plot, stopwords),
  };
}

function formatRuntime(runtime) {
  if (!runtime) {
    return "Unknown runtime";
  }

  return `${runtime} min`;
}

function formatScore(score) {
  return `${Math.round(score * 100)}% match`;
}

function setStatus(message, type = "") {
  elements.status.textContent = message;
  elements.status.className = type ? `movie-status ${type}` : "movie-status";
}

function createPosterElement(movie, className = "movie-poster") {
  if (movie.posterUrl) {
    const image = document.createElement("img");
    image.className = className;
    image.src = movie.posterUrl;
    image.alt = `${movie.title} poster`;
    image.loading = "lazy";
    image.referrerPolicy = "no-referrer";
    image.addEventListener("error", () => {
      const fallback = document.createElement("div");
      fallback.className = `${className} movie-poster-fallback`;
      fallback.textContent = movie.title;
      image.replaceWith(fallback);
    });
    return image;
  }

  const fallback = document.createElement("div");
  fallback.className = `${className} movie-poster-fallback`;
  fallback.textContent = movie.title;
  return fallback;
}

function populateMovieSelect() {
  const sorted = [...state.movies].sort((left, right) => left.title.localeCompare(right.title));
  elements.movieSelect.innerHTML = '<option value="">Choose a movie...</option>';

  sorted.forEach((movie) => {
    const option = document.createElement("option");
    option.value = String(movie.id);
    option.textContent = `${movie.title} (${movie.year})`;
    elements.movieSelect.appendChild(option);
  });
}

function populateFilters() {
  const genres = [...new Set(state.movies.flatMap((movie) => movie.genres))].sort();
  const decades = [...new Set(state.movies.map((movie) => movie.decade).filter(Boolean))].sort((a, b) => a - b);

  elements.genreFilter.innerHTML = '<option value="All">All genres</option>';
  genres.forEach((genre) => {
    const option = document.createElement("option");
    option.value = genre;
    option.textContent = genre;
    elements.genreFilter.appendChild(option);
  });

  elements.decadeFilter.innerHTML = '<option value="All">All decades</option>';
  decades.forEach((decade) => {
    const option = document.createElement("option");
    option.value = String(decade);
    option.textContent = `${decade}s`;
    elements.decadeFilter.appendChild(option);
  });
}

function renderSummary() {
  const years = state.movies.map((movie) => movie.year).filter(Boolean);
  const runtimes = state.movies.map((movie) => movie.runtime).filter(Boolean);
  const allGenres = new Set(state.movies.flatMap((movie) => movie.genres));

  elements.summaryMovieCount.textContent = String(state.movies.length);
  elements.summaryGenreCount.textContent = String(allGenres.size);
  elements.summaryYearRange.textContent = `${Math.min(...years)}-${Math.max(...years)}`;
  elements.summaryRuntime.textContent = `${Math.round(average(runtimes))} min`;
}

function getSelectedMovie() {
  const id = Number(elements.movieSelect.value);
  if (!id) {
    return null;
  }
  return state.movies.find((movie) => movie.id === id) || null;
}

function getFilteredCandidates(selectedMovie) {
  return state.movies.filter((movie) => {
    if (movie.id === selectedMovie.id) {
      return false;
    }

    if (elements.genreFilter.value !== "All" && !movie.genres.includes(elements.genreFilter.value)) {
      return false;
    }

    if (elements.decadeFilter.value !== "All" && movie.decade !== Number(elements.decadeFilter.value)) {
      return false;
    }

    if (elements.runtimeFilter.value === "short" && movie.runtime >= 100) {
      return false;
    }

    if (elements.runtimeFilter.value === "medium" && (movie.runtime < 100 || movie.runtime > 130)) {
      return false;
    }

    if (elements.runtimeFilter.value === "long" && movie.runtime <= 130) {
      return false;
    }

    return true;
  });
}

function computeSimilarity(selectedMovie, candidateMovie) {
  const weights = state.config.weights;
  const sharedGenres = intersection(selectedMovie.genres, candidateMovie.genres);
  const genreUnion = new Set([...selectedMovie.genres, ...candidateMovie.genres]);
  const genreOverlap = genreUnion.size ? sharedGenres.length / genreUnion.size : 0;

  const yearDiff = Math.abs(selectedMovie.year - candidateMovie.year);
  const yearProximity = 1 - Math.min(yearDiff, state.config.yearWindow) / state.config.yearWindow;

  const runtimeDiff = Math.abs(selectedMovie.runtime - candidateMovie.runtime);
  const runtimeProximity = 1 - Math.min(runtimeDiff, state.config.runtimeWindow) / state.config.runtimeWindow;

  const directorMatch = selectedMovie.director && selectedMovie.director === candidateMovie.director ? 1 : 0;
  const sharedActors = intersection(selectedMovie.actors, candidateMovie.actors);
  const actorBase = Math.max(3, Math.min(selectedMovie.actors.length, 4));
  const actorOverlap = Math.min(sharedActors.length / actorBase, 1);

  const sharedKeywords = intersection(selectedMovie.keywords, candidateMovie.keywords);
  const keywordBase = Math.max(4, Math.min(selectedMovie.keywords.length, 8));
  const plotKeywordOverlap = Math.min(sharedKeywords.length / keywordBase, 1);

  const components = {
    genreOverlap,
    yearProximity,
    runtimeProximity,
    directorMatch,
    actorOverlap,
    plotKeywordOverlap,
  };

  const score = Object.entries(weights).reduce((sum, [key, weight]) => sum + components[key] * weight, 0);

  const reasons = [];
  if (sharedGenres.length) {
    reasons.push(`Genres: ${sharedGenres.slice(0, 2).join(", ")}`);
  }
  if (directorMatch) {
    reasons.push("Same director");
  }
  if (sharedActors.length) {
    reasons.push(`Cast overlap: ${sharedActors.slice(0, 2).join(", ")}`);
  }
  if (yearDiff <= 5) {
    reasons.push("Similar release era");
  }
  if (runtimeDiff <= 15) {
    reasons.push("Similar runtime");
  }
  if (sharedKeywords.length) {
    reasons.push(`Story overlap: ${sharedKeywords.slice(0, 2).join(", ")}`);
  }

  return {
    movie: candidateMovie,
    score,
    components,
    sharedGenres,
    sharedActors,
    sharedKeywords,
    yearDiff,
    runtimeDiff,
    reasons: reasons.slice(0, 4),
  };
}

function renderSelectedMovie(movie) {
  elements.selectedMoviePanel.innerHTML = "";
  if (!movie) {
    elements.selectedMoviePanel.innerHTML = '<div class="empty-state">Choose a movie and click <strong>Recommend Movies</strong> to generate results.</div>';
    return;
  }

  const wrapper = document.createElement("div");
  wrapper.className = "selected-movie";

  wrapper.appendChild(createPosterElement(movie));

  const body = document.createElement("div");
  const meta = movie.genres.map((genre) => `<span class="movie-pill">${genre}</span>`).join("");

  body.innerHTML = `
    <p class="eyebrow">Selected movie</p>
    <h3>${movie.title}</h3>
    <div class="movie-meta">
      <span class="movie-pill">${movie.year}</span>
      <span class="movie-pill">${formatRuntime(movie.runtime)}</span>
      <span class="movie-pill">${movie.director || "Unknown director"}</span>
    </div>
    <div class="movie-meta">${meta}</div>
    <p>${movie.plot}</p>
    <p class="movie-helper"><strong>Cast:</strong> ${movie.actors.slice(0, 4).join(", ") || "Unknown cast"}</p>
  `;

  wrapper.appendChild(body);
  elements.selectedMoviePanel.appendChild(wrapper);
}

function renderRecommendations(results) {
  elements.recommendationsGrid.innerHTML = "";

  if (!results.length) {
    elements.recommendationsGrid.innerHTML = '<div class="empty-state">No recommendations matched the current filters. Try widening the filters or choosing a different movie.</div>';
    return;
  }

  results.forEach((result) => {
    const card = document.createElement("article");
    card.className = "recommendation-card";

    const top = document.createElement("div");
    top.className = "recommendation-top";
    top.appendChild(createPosterElement(result.movie));

    const body = document.createElement("div");
    body.innerHTML = `
      <span class="score-badge">${formatScore(result.score)}</span>
      <h3>${result.movie.title}</h3>
      <p class="movie-helper">${result.movie.year} · ${formatRuntime(result.movie.runtime)} · ${result.movie.director || "Unknown director"}</p>
      <p>${result.movie.plot}</p>
    `;

    top.appendChild(body);
    card.appendChild(top);

    const reasons = document.createElement("div");
    reasons.className = "recommendation-reasons";
    result.reasons.forEach((reason) => {
      const chip = document.createElement("span");
      chip.className = "reason-chip";
      chip.textContent = reason;
      reasons.appendChild(chip);
    });
    card.appendChild(reasons);

    elements.recommendationsGrid.appendChild(card);
  });
}

function renderBars(target, items, formatter = (value) => value.toFixed(2), useSecondary = false) {
  target.innerHTML = "";

  if (!items.length) {
    target.innerHTML = '<div class="empty-state">No chart data available for the current recommendation set.</div>';
    return;
  }

  const stack = document.createElement("div");
  stack.className = "chart-stack";

  items.forEach((item) => {
    const row = document.createElement("div");
    row.className = "bar-row";
    row.innerHTML = `
      <div class="bar-meta">
        <span>${item.label}</span>
        <span>${formatter(item.value)}</span>
      </div>
      <div class="bar-track">
        <span class="bar-fill ${useSecondary ? "secondary" : ""}" style="width: ${Math.max(item.value * 100, 4)}%"></span>
      </div>
    `;
    stack.appendChild(row);
  });

  target.appendChild(stack);
}

function renderYearTimeline(target, results) {
  target.innerHTML = "";

  if (!results.length) {
    target.innerHTML = '<div class="empty-state">No recommendation timeline available yet.</div>';
    return;
  }

  const list = document.createElement("div");
  list.className = "year-list";

  results
    .slice()
    .sort((left, right) => left.movie.year - right.movie.year)
    .forEach((result) => {
      const item = document.createElement("div");
      item.className = "year-item";
      item.innerHTML = `
        <span>${result.movie.year}</span>
        <div class="bar-track">
          <span class="bar-fill secondary" style="width: ${Math.max(result.score * 100, 4)}%"></span>
        </div>
        <strong>${Math.round(result.score * 100)}%</strong>
      `;
      list.appendChild(item);
    });

  target.appendChild(list);
}

function renderCharts(results) {
  const averageDrivers = Object.keys(state.config.weights).map((key) => ({
    label:
      {
        genreOverlap: "Genre overlap",
        yearProximity: "Year proximity",
        runtimeProximity: "Runtime proximity",
        directorMatch: "Director match",
        actorOverlap: "Actor overlap",
        plotKeywordOverlap: "Plot keyword overlap",
      }[key] || key,
    value: average(results.map((result) => result.components[key] || 0)),
  }));

  const genreCounts = new Map();
  results.forEach((result) => {
    result.movie.genres.forEach((genre) => {
      genreCounts.set(genre, (genreCounts.get(genre) || 0) + 1);
    });
  });

  const topGenres = [...genreCounts.entries()]
    .sort((left, right) => right[1] - left[1])
    .slice(0, 6)
    .map(([label, count]) => ({
      label,
      value: count / Math.max(results.length, 1),
    }));

  renderBars(elements.similarityChart, averageDrivers, (value) => `${Math.round(value * 100)}%`);
  renderBars(elements.genreChart, topGenres, (value) => `${Math.round(value * 100)}% of recs`, true);
  renderYearTimeline(elements.yearChart, results);
}

function renderComparisonTable(results) {
  elements.comparisonTableBody.innerHTML = "";

  if (!results.length) {
    return;
  }

  results.forEach((result) => {
    const row = document.createElement("tr");
    row.innerHTML = `
      <td>${result.movie.title}</td>
      <td>${Math.round(result.score * 100)}%</td>
      <td>${result.sharedGenres.slice(0, 2).join(", ") || "None"}</td>
      <td>${result.sharedActors.slice(0, 2).join(", ") || "None"}</td>
      <td>${result.yearDiff} yrs</td>
      <td>${result.runtimeDiff} min</td>
      <td>${result.movie.director === getSelectedMovie()?.director ? "Yes" : "No"}</td>
    `;
    elements.comparisonTableBody.appendChild(row);
  });
}

function runRecommendations() {
  const selectedMovie = getSelectedMovie();

  if (!selectedMovie) {
    setStatus("Choose a movie before generating recommendations.", "error");
    renderSelectedMovie(null);
    renderRecommendations([]);
    renderCharts([]);
    renderComparisonTable([]);
    return;
  }

  const candidates = getFilteredCandidates(selectedMovie);
  const results = candidates
    .map((candidate) => computeSimilarity(selectedMovie, candidate))
    .filter((result) => result.score >= state.config.minimumScore)
    .sort((left, right) => right.score - left.score)
    .slice(0, state.config.topResults);

  renderSelectedMovie(selectedMovie);
  renderRecommendations(results);
  renderCharts(results);
  renderComparisonTable(results);

  if (!results.length) {
    setStatus("No strong matches were found with the current filters. Try widening the filter settings.", "error");
  } else {
    setStatus(`Generated ${results.length} recommendations for ${selectedMovie.title}.`, "success");
  }
}

function pickRandomMovie() {
  const featuredPool = state.movies.filter((movie) => state.config.featuredTitles.includes(movie.title));
  const pool = featuredPool.length ? featuredPool : state.movies;
  const randomMovie = pool[Math.floor(Math.random() * pool.length)];
  elements.movieSelect.value = String(randomMovie.id);
  runRecommendations();
}

function wireEvents() {
  elements.recommendButton.addEventListener("click", runRecommendations);
  elements.randomButton.addEventListener("click", pickRandomMovie);
  [elements.genreFilter, elements.decadeFilter, elements.runtimeFilter].forEach((select) => {
    select.addEventListener("change", () => {
      if (getSelectedMovie()) {
        runRecommendations();
      }
    });
  });
  elements.movieSelect.addEventListener("change", () => {
    const selectedMovie = getSelectedMovie();
    renderSelectedMovie(selectedMovie);
    if (selectedMovie) {
      setStatus("Movie selected. Click Recommend Movies to refresh the results.");
    } else {
      setStatus("Choose a movie and click Recommend Movies to generate results.");
    }
  });
}

async function initialize() {
  try {
    const [dataset, config] = await Promise.all([
      fetch(MOVIES_URL).then((response) => response.json()),
      fetch(CONFIG_URL).then((response) => response.json()),
    ]);

    state.config = config;
    const stopwords = new Set(config.plotStopwords || []);
    state.movies = (dataset.movies || []).map((movie) => normalizeMovie(movie, stopwords));

    populateMovieSelect();
    populateFilters();
    renderSummary();
    renderSelectedMovie(null);
    wireEvents();
    setStatus("Movie metadata loaded. Choose a title and click Recommend Movies.", "success");
  } catch (error) {
    console.error(error);
    setStatus("The movie explorer could not load its data. Make sure the page is served over a local web server or GitHub Pages.", "error");
  }
}

initialize();
