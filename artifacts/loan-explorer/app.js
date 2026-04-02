const DATA_URL = "./loan-explorer/loan-approval-dataset.csv";
const MODEL_URL = "./loan-explorer/model-config.json";

const numberFormatter = new Intl.NumberFormat("en-US");
const compactFormatter = new Intl.NumberFormat("en-US", {
  notation: "compact",
  maximumFractionDigits: 1,
});

const state = {
  model: null,
  records: [],
  ranges: {},
};

const elements = {
  status: document.getElementById("loan-dashboard-status"),
  presetRow: document.getElementById("preset-row"),
  summaryRecords: document.getElementById("summary-records"),
  summaryApprovalRate: document.getElementById("summary-approval-rate"),
  summaryCibil: document.getElementById("summary-cibil"),
  summaryLoan: document.getElementById("summary-loan"),
  form: {
    dependents: document.getElementById("input-dependents"),
    education: document.getElementById("input-education"),
    selfEmployed: document.getElementById("input-self-employed"),
    income: document.getElementById("input-income"),
    loanAmount: document.getElementById("input-loan-amount"),
    loanTerm: document.getElementById("input-loan-term"),
    cibil: document.getElementById("input-cibil"),
    residential: document.getElementById("input-residential"),
    commercial: document.getElementById("input-commercial"),
    luxury: document.getElementById("input-luxury"),
    bank: document.getElementById("input-bank"),
  },
  filters: {
    education: document.getElementById("filter-education"),
    selfEmployed: document.getElementById("filter-employment"),
    status: document.getElementById("filter-status"),
  },
  probability: document.getElementById("probability-number"),
  badge: document.getElementById("prediction-badge"),
  explanation: document.getElementById("prediction-copy"),
  meter: document.getElementById("meter-fill"),
  drivers: document.getElementById("driver-list"),
  similarTable: document.getElementById("similar-table-body"),
  scatter: document.getElementById("scatter-chart"),
  creditBand: document.getElementById("credit-band-chart"),
  ratioChart: document.getElementById("ratio-chart"),
};

function loadCsv(url) {
  return new Promise((resolve, reject) => {
    Papa.parse(url, {
      download: true,
      header: true,
      dynamicTyping: true,
      skipEmptyLines: true,
      complete: (results) => resolve(results.data),
      error: reject,
    });
  });
}

function normalizeRows(rows) {
  return rows.map((row) => {
    const income = Number(row.income_annum);
    const loanAmount = Number(row.loan_amount);
    const residential = Number(row.residential_assets_value);
    const commercial = Number(row.commercial_assets_value);
    const luxury = Number(row.luxury_assets_value);
    const bank = Number(row.bank_asset_value);
    const totalAssets = residential + commercial + luxury + bank;

    return {
      loanId: Number(row.loan_id),
      dependents: Number(row.no_of_dependents),
      education: String(row.education).trim(),
      selfEmployed: String(row.self_employed).trim(),
      income,
      loanAmount,
      loanTerm: Number(row.loan_term),
      cibil: Number(row.cibil_score),
      residential,
      commercial,
      luxury,
      bank,
      totalAssets,
      status: String(row.loan_status).trim(),
      approved: String(row.loan_status).trim() === "Approved",
      loanToIncome: loanAmount / Math.max(income, 1),
      assetCoverage: totalAssets / Math.max(loanAmount, 1),
    };
  });
}

function buildRanges(records) {
  const keys = ["income", "loanAmount", "loanTerm", "cibil", "dependents", "bank", "loanToIncome", "assetCoverage"];
  const ranges = {};

  keys.forEach((key) => {
    const values = records.map((record) => record[key]);
    ranges[key] = {
      min: Math.min(...values),
      max: Math.max(...values),
    };
  });

  return ranges;
}

function computeMedian(values) {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  if (sorted.length % 2 === 0) {
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }
  return sorted[middle];
}

function sigmoid(value) {
  return 1 / (1 + Math.exp(-value));
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function formatCompact(value) {
  return compactFormatter.format(value);
}

function buildScenarioFromForm() {
  return {
    dependents: Number(elements.form.dependents.value),
    education: elements.form.education.value,
    selfEmployed: elements.form.selfEmployed.value,
    income: Number(elements.form.income.value),
    loanAmount: Number(elements.form.loanAmount.value),
    loanTerm: Number(elements.form.loanTerm.value),
    cibil: Number(elements.form.cibil.value),
    residential: Number(elements.form.residential.value),
    commercial: Number(elements.form.commercial.value),
    luxury: Number(elements.form.luxury.value),
    bank: Number(elements.form.bank.value),
  };
}

function deriveScenarioMetrics(inputs) {
  const totalAssets = inputs.residential + inputs.commercial + inputs.luxury + inputs.bank;
  return {
    totalAssets,
    loanToIncome: inputs.loanAmount / Math.max(inputs.income, 1),
    assetCoverage: totalAssets / Math.max(inputs.loanAmount, 1),
  };
}

function predictScenario(inputs) {
  const derived = deriveScenarioMetrics(inputs);
  let score = state.model.bias;
  const contributions = [];

  Object.entries(state.model.numericFeatures).forEach(([key, config]) => {
    const rawValue = Number(inputs[key]);
    const centered = (rawValue - config.center) / config.scale;
    const contribution = centered * config.weight;
    score += contribution;
    contributions.push({
      label: config.label,
      contribution,
    });
  });

  Object.entries(state.model.derivedFeatures).forEach(([key, config]) => {
    const rawValue = Number(derived[key]);
    const centered = (rawValue - config.center) / config.scale;
    const contribution = centered * config.weight;
    score += contribution;
    contributions.push({
      label: config.label,
      contribution,
    });
  });

  Object.entries(state.model.categoricalWeights).forEach(([key, config]) => {
    const selectedValue = inputs[key];
    const contribution = config.weights[selectedValue] ?? 0;
    score += contribution;
    contributions.push({
      label: config.label,
      contribution,
    });
  });

  contributions.sort((left, right) => Math.abs(right.contribution) - Math.abs(left.contribution));

  const probability = sigmoid(score);
  const likelyApproval = probability >= state.model.approvalThreshold;

  return {
    probability,
    likelyApproval,
    derived,
    topDrivers: contributions.slice(0, 6),
  };
}

function renderSummaryCards() {
  const approvalRate =
    state.records.filter((record) => record.approved).length / Math.max(state.records.length, 1);
  const averageCibil =
    state.records.reduce((sum, record) => sum + record.cibil, 0) / Math.max(state.records.length, 1);
  const medianLoan = computeMedian(state.records.map((record) => record.loanAmount));

  elements.summaryRecords.textContent = numberFormatter.format(state.records.length);
  elements.summaryApprovalRate.textContent = `${(approvalRate * 100).toFixed(1)}%`;
  elements.summaryCibil.textContent = averageCibil.toFixed(0);
  elements.summaryLoan.textContent = formatCompact(medianLoan);
}

function setPreset(inputs) {
  Object.entries(inputs).forEach(([key, value]) => {
    if (elements.form[key]) {
      elements.form[key].value = String(value);
    }
  });
}

function renderPresets() {
  elements.presetRow.innerHTML = "";

  state.model.presets.forEach((preset, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "preset-button";
    button.textContent = preset.label;
    button.addEventListener("click", () => {
      setPreset(preset.inputs);
      renderScenario();
    });

    elements.presetRow.appendChild(button);

    if (index === 0) {
      setPreset(preset.inputs);
    }
  });
}

function renderDriverList(drivers) {
  elements.drivers.innerHTML = "";

  drivers.forEach((driver) => {
    const row = document.createElement("div");
    row.className = "driver-row";

    const meta = document.createElement("div");
    meta.className = "driver-meta";
    meta.innerHTML = `
      <span>${driver.label}</span>
      <span>${driver.contribution > 0 ? "+" : ""}${driver.contribution.toFixed(2)}</span>
    `;

    const bar = document.createElement("div");
    bar.className = "driver-bar";

    const fill = document.createElement("span");
    fill.className = driver.contribution >= 0 ? "positive" : "negative";
    fill.style.width = `${clamp(Math.abs(driver.contribution) * 28, 6, 100)}%`;

    bar.appendChild(fill);
    row.append(meta, bar);
    elements.drivers.appendChild(row);
  });
}

function scenarioDistance(record, scenario, derived) {
  const recordDerived = {
    loanToIncome: record.loanToIncome,
    assetCoverage: record.assetCoverage,
  };

  const numericKeys = ["income", "loanAmount", "loanTerm", "cibil", "dependents", "bank"];
  let distance = 0;

  numericKeys.forEach((key) => {
    const range = state.ranges[key].max - state.ranges[key].min || 1;
    distance += Math.pow((record[key] - scenario[key]) / range, 2);
  });

  ["loanToIncome", "assetCoverage"].forEach((key) => {
    const range = state.ranges[key].max - state.ranges[key].min || 1;
    distance += Math.pow((recordDerived[key] - derived[key]) / range, 2);
  });

  if (record.education !== scenario.education) {
    distance += 0.35;
  }

  if (record.selfEmployed !== scenario.selfEmployed) {
    distance += 0.25;
  }

  return Math.sqrt(distance);
}

function renderSimilarTable(scenario, derived) {
  const nearest = [...state.records]
    .map((record) => ({
      ...record,
      distance: scenarioDistance(record, scenario, derived),
    }))
    .sort((left, right) => left.distance - right.distance)
    .slice(0, 5);

  elements.similarTable.innerHTML = "";

  nearest.forEach((record) => {
    const row = document.createElement("tr");
    row.innerHTML = `
      <td>#${record.loanId}</td>
      <td>${record.cibil}</td>
      <td>${formatCompact(record.income)}</td>
      <td>${formatCompact(record.loanAmount)}</td>
      <td>${record.loanTerm}</td>
      <td>${record.education}</td>
      <td>${record.selfEmployed}</td>
      <td><span class="status-pill ${record.approved ? "approved" : "rejected"}">${record.status}</span></td>
    `;
    elements.similarTable.appendChild(row);
  });
}

function renderScenario() {
  const scenario = buildScenarioFromForm();
  const prediction = predictScenario(scenario);
  const probabilityPercent = (prediction.probability * 100).toFixed(1);

  elements.probability.textContent = `${probabilityPercent}%`;
  elements.badge.textContent = prediction.likelyApproval ? "Approval looks likely" : "Needs deeper review";
  elements.badge.className = `prediction-badge ${prediction.likelyApproval ? "approve" : "review"}`;
  elements.meter.style.width = `${probabilityPercent}%`;
  elements.explanation.textContent = prediction.likelyApproval
    ? "The current mix of income, assets, and credit quality supports an approval-oriented profile."
    : "The current mix of leverage, credit quality, or assets points toward a higher review risk.";

  renderDriverList(prediction.topDrivers);
  renderSimilarTable(scenario, prediction.derived);
  renderCharts(scenario);
}

function getFilteredRecords() {
  return state.records.filter((record) => {
    const educationMatch =
      elements.filters.education.value === "All" || record.education === elements.filters.education.value;
    const employmentMatch =
      elements.filters.selfEmployed.value === "All" || record.selfEmployed === elements.filters.selfEmployed.value;
    const statusMatch =
      elements.filters.status.value === "All" || record.status === elements.filters.status.value;

    return educationMatch && employmentMatch && statusMatch;
  });
}

function renderEmptyChart(target, title) {
  Plotly.react(
    target,
    [],
    {
      title,
      paper_bgcolor: "rgba(0,0,0,0)",
      plot_bgcolor: "rgba(0,0,0,0)",
      font: { color: "#f9f7ff" },
      xaxis: { visible: false },
      yaxis: { visible: false },
      annotations: [
        {
          text: "No rows match the current filters.",
          showarrow: false,
          font: { size: 16, color: "#d7d0f2" },
        },
      ],
    },
    { responsive: true, displayModeBar: false }
  );
}

function renderCharts(scenario) {
  const filtered = getFilteredRecords();

  if (!filtered.length) {
    renderEmptyChart(elements.scatter, "Historical loans");
    renderEmptyChart(elements.creditBand, "Approval rate by credit band");
    renderEmptyChart(elements.ratioChart, "Loan-to-income by outcome");
    return;
  }

  const approved = filtered.filter((record) => record.approved);
  const rejected = filtered.filter((record) => !record.approved);

  Plotly.react(
    elements.scatter,
    [
      {
        type: "scatter",
        mode: "markers",
        name: "Approved",
        x: approved.map((record) => record.income),
        y: approved.map((record) => record.loanAmount),
        text: approved.map((record) => `Loan #${record.loanId}`),
        marker: {
          color: "#22d3ee",
          size: 11,
          opacity: 0.78,
        },
      },
      {
        type: "scatter",
        mode: "markers",
        name: "Rejected",
        x: rejected.map((record) => record.income),
        y: rejected.map((record) => record.loanAmount),
        text: rejected.map((record) => `Loan #${record.loanId}`),
        marker: {
          color: "#f472b6",
          size: 11,
          opacity: 0.7,
        },
      },
      {
        type: "scatter",
        mode: "markers",
        name: "Current scenario",
        x: [scenario.income],
        y: [scenario.loanAmount],
        marker: {
          color: "#f59e0b",
          size: 18,
          symbol: "diamond",
          line: {
            color: "#fff8c4",
            width: 2,
          },
        },
      },
    ],
    {
      paper_bgcolor: "rgba(0,0,0,0)",
      plot_bgcolor: "rgba(0,0,0,0)",
      font: { color: "#f9f7ff" },
      margin: { t: 20, r: 10, l: 60, b: 50 },
      legend: { orientation: "h", y: 1.08 },
      xaxis: {
        title: "Annual income",
        gridcolor: "rgba(255,255,255,0.08)",
        zerolinecolor: "rgba(255,255,255,0.08)",
      },
      yaxis: {
        title: "Loan amount",
        gridcolor: "rgba(255,255,255,0.08)",
        zerolinecolor: "rgba(255,255,255,0.08)",
      },
    },
    { responsive: true, displayModeBar: false }
  );

  const bands = [
    { label: "< 500", min: -Infinity, max: 500 },
    { label: "500-649", min: 500, max: 650 },
    { label: "650-749", min: 650, max: 750 },
    { label: "750+", min: 750, max: Infinity },
  ];

  const bandSummary = bands.map((band) => {
    const rows = filtered.filter((record) => record.cibil >= band.min && record.cibil < band.max);
    const approvalRate = rows.filter((record) => record.approved).length / Math.max(rows.length, 1);
    return {
      label: band.label,
      count: rows.length,
      approvalRate: approvalRate * 100,
    };
  });

  Plotly.react(
    elements.creditBand,
    [
      {
        type: "bar",
        x: bandSummary.map((band) => band.label),
        y: bandSummary.map((band) => band.approvalRate),
        text: bandSummary.map((band) => `${band.approvalRate.toFixed(1)}%`),
        textposition: "auto",
        marker: {
          color: ["#f472b6", "#f59e0b", "#22d3ee", "#34d399"],
        },
      },
    ],
    {
      paper_bgcolor: "rgba(0,0,0,0)",
      plot_bgcolor: "rgba(0,0,0,0)",
      font: { color: "#f9f7ff" },
      margin: { t: 18, r: 10, l: 50, b: 50 },
      yaxis: {
        title: "Approval rate (%)",
        range: [0, 100],
        gridcolor: "rgba(255,255,255,0.08)",
      },
      xaxis: {
        title: "Credit score band",
      },
    },
    { responsive: true, displayModeBar: false }
  );

  Plotly.react(
    elements.ratioChart,
    [
      {
        type: "box",
        name: "Approved",
        y: approved.map((record) => record.loanToIncome),
        marker: { color: "#22d3ee" },
        boxmean: true,
      },
      {
        type: "box",
        name: "Rejected",
        y: rejected.map((record) => record.loanToIncome),
        marker: { color: "#f472b6" },
        boxmean: true,
      },
    ],
    {
      paper_bgcolor: "rgba(0,0,0,0)",
      plot_bgcolor: "rgba(0,0,0,0)",
      font: { color: "#f9f7ff" },
      margin: { t: 18, r: 10, l: 50, b: 50 },
      yaxis: {
        title: "Loan-to-income ratio",
        gridcolor: "rgba(255,255,255,0.08)",
      },
    },
    { responsive: true, displayModeBar: false }
  );
}

function wireEvents() {
  Object.values(elements.form).forEach((input) => {
    input.addEventListener("input", renderScenario);
    input.addEventListener("change", renderScenario);
  });

  Object.values(elements.filters).forEach((select) => {
    select.addEventListener("change", () => {
      renderCharts(buildScenarioFromForm());
    });
  });
}

async function initializeDashboard() {
  try {
    const [model, rawRows] = await Promise.all([
      fetch(MODEL_URL).then((response) => response.json()),
      loadCsv(DATA_URL),
    ]);

    state.model = model;
    state.records = normalizeRows(rawRows);
    state.ranges = buildRanges(state.records);

    elements.status.textContent = "Dashboard loaded with live client-side data and model scoring.";
    renderSummaryCards();
    renderPresets();
    wireEvents();
    renderScenario();
  } catch (error) {
    console.error(error);
    elements.status.textContent = "The dashboard data could not be loaded. Check the dataset and asset paths.";
  }
}

initializeDashboard();
