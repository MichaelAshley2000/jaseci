"""Script to generate a markdown table of top contributors from local git repository."""

import from datetime { datetime, timedelta }
import from subprocess { run, PIPE }

obj Commit {
    has author_name: str;
    has author_email: str;
    has commit_date: str;
}

obj Contributor {
    has name: str;
    has email: str;
    has commits: int;
    has active_days: int;
}

def get_commits_from_git(days: int) -> list[Commit] {
    # """Get commits from local git repository for the specified number of days."""
    since_date = (datetime.now() - timedelta(days=days)).strftime("%Y-%m-%d");

    cmd = [
        "git", "log",
        f"--since={since_date}",
        "--pretty=format:%an|%ae|%ad",
        "--date=short"
    ];

    try {
        result = run(cmd, stdout=PIPE, stderr=PIPE);
        stdout = result.stdout.decode('utf-8');
        commits = [];

        for line in stdout.strip().split("\n") {
            if len(line) == 0 {
                continue;
            }
            parts = line.split("|");
            if len(parts) == 3 {
                commits.append(Commit(
                    author_name=parts[0],
                    author_email=parts[1],
                    commit_date=parts[2]
                ));
            }
        }
        return commits;
    } except Exception as e {
        print(f"Error fetching commits from git: {e}");
        return [];
    }
}

def process_contributors(commits: list[Commit], days: int) -> list[Contributor] {
    since_date = (datetime.now() - timedelta(days=days)).date();

    # Group by email to deduplicate same person with different names
    contributors: dict[str, dict] = {};
    name_counts: dict[str, dict[str, int]] = {};

    for commit in commits {
        try {
            commit_date = datetime.strptime(commit.commit_date, "%Y-%m-%d").date();
        } except ValueError {
            continue;
        }

        if commit_date > since_date {
            author_email = commit.author_email;
            author_name = commit.author_name;

            if author_email not in contributors {
                contributors[author_email] = {
                    "commits": 0,
                    "active_days": set(),
                    "email": author_email
                };
                name_counts[author_email] = {};
            }

            contributors[author_email]["commits"] = contributors[author_email]["commits"] + 1;
            contributors[author_email]["active_days"].add(commit_date);

            if author_name not in name_counts[author_email] {
                name_counts[author_email][author_name] = 0;
            }
            name_counts[author_email][author_name] = name_counts[author_email][author_name] + 1;
        }
    }

    # Use the most frequently used name for each email
    results = [];
    for email in contributors {
        data = contributors[email];

        # Find most common name
        best_name = email;
        max_count = 0;
        for name in name_counts[email] {
            if name_counts[email][name] > max_count {
                max_count = name_counts[email][name];
                best_name = name;
            }
        }

        results.append(Contributor(
            name=best_name,
            email=email,
            commits=data["commits"],
            active_days=len(data["active_days"])
        ));
    }

    # Sort by commits descending (bubble sort)
    for i in range(len(results)) {
        for j in range(i + 1, len(results)) {
            if results[j].commits > results[i].commits {
                temp = results[i];
                results[i] = results[j];
                results[j] = temp;
            }
        }
    }

    return results;
}

def generate_html_table(contributors: list[Contributor], days: int) -> str {
    if len(contributors) == 0 {
        return f"<p>No contributions found in the last {days} days.</p>";
    }

    end_date = datetime.now().date();
    start_date = end_date - timedelta(days=days);

    lines = [];
    lines.append(f"<h3>Top contributors in the last {days} days ({start_date.strftime('%Y-%m-%d')} to {end_date.strftime('%Y-%m-%d')})</h3>");
    lines.append("<table>");
    lines.append("<thead><tr><th>Contributor</th><th>Commits</th><th>Active Days</th></tr></thead>");
    lines.append("<tbody>");

    for c in contributors {
        lines.append(f"<tr><td>{c.name}</td><td>{c.commits}</td><td>{c.active_days}</td></tr>");
    }

    lines.append("</tbody></table>");
    return "\n".join(lines);
}

def get_tabs_css() -> str {
    return """
<style>
#tabs {
    display: flex;
    justify-content: space-between;
    padding: 0;
    margin: 0 0 1em 0;
    border-bottom: 2px solid #222;
    background: #23272e;
    list-style: none;
    width: 100%;
}
#tabs li {
    flex: 1 1 0;
    padding: 0.7em 1.5em;
    margin: 0;
    cursor: pointer;
    border: 1px solid #222;
    border-bottom: none;
    background: #23272e;
    color: #bfc7d5;
    border-radius: 8px 8px 0 0;
    transition: background 0.2s, color 0.2s;
    font-weight: 500;
    min-width: 0;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}
#tabs li.active, #tabs li:hover {
    background: #181b20;
    color: #fff;
    font-weight: bold;
    border-bottom: 2px solid #181b20;
    box-shadow: 0 -2px 8px #181b20;
    z-index: 2;
}
.tabcontent {
    border: 1px solid #222;
    border-radius: 0 0 8px 8px;
    padding: 1.5em;
    margin-bottom: 2em;
    box-shadow: 0 2px 8px rgba(0,0,0,0.12);
    color: #e0e6ed;
}
.tabcontent table {
    width: 100%;
    border-collapse: collapse;
    margin: 1em 0;
    font-size: 1em;
    background: #23272e;
    color: #e0e6ed;
}
.tabcontent th, .tabcontent td {
    border: 1px solid #222;
    padding: 0.7em 1em;
    text-align: left;
}
.tabcontent th {
    background: #181b20;
    color: #7ecfff;
    font-weight: 600;
}
.tabcontent tr:nth-child(even) {
    background: #23272e;
}
.tabcontent tr:hover {
    background: #2a313a;
}
</style>
""";
}

def main(days_arg: int = None) {
    periods = [];
    if days_arg != None {
        periods.append(days_arg);
    }
    for p in [7, 30, 180, 365] {
        if p not in periods {
            periods.append(p);
        }
    }
    if len(periods) == 0 {
        return;
    }

    # Fetch commits once for the maximum period
    max_days = 0;
    for p in periods {
        if p > max_days {
            max_days = p;
        }
    }
    all_commits = get_commits_from_git(max_days);

    # Generate tables for each period
    html = [];
    html.append(get_tabs_css());
    html.append('<div class="tabcontent">');

    for days in periods {
        contributors = process_contributors(all_commits, days);
        html.append(generate_html_table(contributors, days));
    }

    html.append("</div>");
    print("\n".join(html));
}

with entry {
    # Parse command line arguments
    days_override = None;
    # Check if --days argument is provided
    # Note: Jac CLI argument handling may vary
    main(days_arg=days_override);
}
