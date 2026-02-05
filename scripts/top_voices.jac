"""Script to generate a markdown table of top voices from GitHub discussions."""

import from datetime { datetime, timedelta, timezone }
import from subprocess { run, PIPE }
import from json { loads }

glob REPO = "Jaseci-Labs/jaseci";
glob PER_PAGE = 100;
glob MAX_PR_LIMIT = 500;
glob DEFAULT_PERIODS = [7, 30, 180, 365];

obj VoiceEntry {
    has author: str;
    has date: str;
}

obj VoiceStats {
    has name: str;
    has comments: int;
    has reviews: int;
    has issues: int;
    has active_days: int;
    has total: int;
}

def check_gh_cli() -> bool {
    try {
        result = run(["gh", "auth", "status"], stdout=PIPE, stderr=PIPE);
        return result.returncode == 0;
    } except Exception {
        return False;
    }
}

def is_bot(user_data: dict) -> bool {
    user_type = user_data.get("type", "").lower();
    login = user_data.get("login", "").lower();
    return user_type == "bot" or "[bot]" in login;
}

def is_bot_str(user_identifier: str) -> bool {
    return "[bot]" in user_identifier.lower();
}

def paginated_api(endpoint: str) -> list[dict] {
    items = [];
    page = 1;
    while True {
        cmd = ["gh", "api", f"{endpoint}&per_page={PER_PAGE}&page={page}"];
        result = run(cmd, stdout=PIPE, stderr=PIPE);
        if result.returncode != 0 {
            break;
        }
        data = loads(result.stdout.decode('utf-8'));
        if len(data) == 0 {
            break;
        }
        for item in data {
            items.append(item);
        }
        if len(data) < PER_PAGE {
            break;
        }
        page = page + 1;
    }
    return items;
}

def fetch_comments(since_date: str) -> list[VoiceEntry] {
    comments = [];

    for item in paginated_api(f"/repos/{REPO}/issues/comments?since={since_date}") {
        if not is_bot(item.get("user", {})) {
            comments.append(VoiceEntry(
                author=item["user"].get("login", "unknown"),
                date=item.get("created_at", "")
            ));
        }
    }

    for item in paginated_api(f"/repos/{REPO}/pulls/comments?since={since_date}") {
        if not is_bot(item.get("user", {})) {
            comments.append(VoiceEntry(
                author=item["user"].get("login", "unknown"),
                date=item.get("created_at", "")
            ));
        }
    }

    return comments;
}

def fetch_reviews(since_date: str) -> list[VoiceEntry] {
    reviews = [];
    cmd = [
        "gh", "pr", "list",
        "--repo", f"{REPO}",
        "--state", "merged",
        "--limit", f"{MAX_PR_LIMIT}",
        "--json", "number,updatedAt,mergedAt"
    ];
    result = run(cmd, stdout=PIPE, stderr=PIPE);
    if result.returncode != 0 {
        return reviews;
    }

    since_dt = datetime.fromisoformat(since_date.replace("Z", "+00:00"));
    pr_list = loads(result.stdout.decode('utf-8'));

    for pr in pr_list {
        pr_date = pr.get("mergedAt") or pr.get("updatedAt");
        if not pr_date {
            continue;
        }
        pr_date_dt = datetime.fromisoformat(pr_date.replace("Z", "+00:00"));
        if pr_date_dt < since_dt {
            continue;
        }

        review_cmd = ["gh", "api", f"/repos/{REPO}/pulls/{pr['number']}/reviews"];
        review_result = run(review_cmd, stdout=PIPE, stderr=PIPE);
        if review_result.returncode == 0 {
            for review in loads(review_result.stdout.decode('utf-8')) {
                if is_bot(review.get("user", {})) {
                    continue;
                }
                review_date = review.get("submitted_at", "");
                if review_date {
                    review_dt = datetime.fromisoformat(review_date.replace("Z", "+00:00"));
                    if review_dt >= since_dt {
                        reviews.append(VoiceEntry(
                            author=review["user"].get("login", "unknown"),
                            date=review_date
                        ));
                    }
                }
            }
        }
    }
    return reviews;
}

def fetch_issues(since_date: str) -> list[VoiceEntry] {
    cmd = [
        "gh", "issue", "list",
        "--repo", f"{REPO}",
        "--limit", f"{MAX_PR_LIMIT}",
        "--search", f"created:>{since_date[:10]}",
        "--json", "author,createdAt"
    ];
    result = run(cmd, stdout=PIPE, stderr=PIPE);
    if result.returncode != 0 {
        return [];
    }

    issues = [];
    for item in loads(result.stdout.decode('utf-8')) {
        if not is_bot(item.get("author", {})) {
            issues.append(VoiceEntry(
                author=item["author"].get("login", "unknown"),
                date=item.get("createdAt", "")
            ));
        }
    }
    return issues;
}

def fetch_real_names(usernames: list[str]) -> dict[str, str] {
    names = {};
    for username in usernames {
        if username == "unknown" {
            continue;
        }
        cmd = ["gh", "api", "/users/" + username];
        result = run(cmd, stdout=PIPE, stderr=PIPE);
        if result.returncode == 0 {
            user_data = loads(result.stdout.decode('utf-8'));
            name = user_data.get("name");
            if name and name.lower() != username.lower() {
                names[username] = name;
            }
        }
    }
    return names;
}

def process_voices(
    comments: list[VoiceEntry],
    reviews: list[VoiceEntry],
    issues: list[VoiceEntry],
    days: int
) -> list[VoiceStats] {
    since_date = (datetime.now(timezone.utc) - timedelta(days=days)).replace(tzinfo=None);

    # Voice data structure per username
    voices: dict[str, dict] = {};
    all_usernames: list[str] = [];

    # Process comments
    for item in comments {
        try {
            date = datetime.fromisoformat(item.date.replace("Z", "+00:00")).replace(tzinfo=None);
            if date < since_date {
                continue;
            }
        } except ValueError {
            continue;
        }

        author = item.author;
        if author == "unknown" or is_bot_str(author) {
            continue;
        }

        if author not in all_usernames {
            all_usernames.append(author);
        }

        if author not in voices {
            voices[author] = {
                "comments": 0,
                "reviews": 0,
                "issues": 0,
                "active_days": set()
            };
        }
        voices[author]["comments"] = voices[author]["comments"] + 1;
        voices[author]["active_days"].add(date.date());
    }

    # Process reviews
    for item in reviews {
        try {
            date = datetime.fromisoformat(item.date.replace("Z", "+00:00")).replace(tzinfo=None);
            if date < since_date {
                continue;
            }
        } except ValueError {
            continue;
        }

        author = item.author;
        if author == "unknown" or is_bot_str(author) {
            continue;
        }

        if author not in all_usernames {
            all_usernames.append(author);
        }

        if author not in voices {
            voices[author] = {
                "comments": 0,
                "reviews": 0,
                "issues": 0,
                "active_days": set()
            };
        }
        voices[author]["reviews"] = voices[author]["reviews"] + 1;
        voices[author]["active_days"].add(date.date());
    }

    # Process issues
    for item in issues {
        try {
            date = datetime.fromisoformat(item.date.replace("Z", "+00:00")).replace(tzinfo=None);
            if date < since_date {
                continue;
            }
        } except ValueError {
            continue;
        }

        author = item.author;
        if author == "unknown" or is_bot_str(author) {
            continue;
        }

        if author not in all_usernames {
            all_usernames.append(author);
        }

        if author not in voices {
            voices[author] = {
                "comments": 0,
                "reviews": 0,
                "issues": 0,
                "active_days": set()
            };
        }
        voices[author]["issues"] = voices[author]["issues"] + 1;
        voices[author]["active_days"].add(date.date());
    }

    print("Fetching names for " + str(len(all_usernames)) + " users...");

    real_names = fetch_real_names(all_usernames);

    results = [];
    for username in voices {
        if is_bot_str(username) {
            continue;
        }
        data = voices[username];
        display_name = real_names.get(username, username);
        if is_bot_str(display_name) {
            continue;
        }
        total = data["comments"] + data["reviews"] + data["issues"];
        results.append(VoiceStats(
            name=display_name,
            comments=data["comments"],
            reviews=data["reviews"],
            issues=data["issues"],
            active_days=len(data["active_days"]),
            total=total
        ));
    }

    # Sort by total descending (bubble sort)
    for i in range(len(results)) {
        for j in range(i + 1, len(results)) {
            if results[j].total > results[i].total {
                temp = results[i];
                results[i] = results[j];
                results[j] = temp;
            }
        }
    }

    return results;
}

def generate_html_table(voices: list[VoiceStats], days: int) -> str {
    if len(voices) == 0 {
        return "<p>No discussion activity found in the last " + str(days) + " days.</p>";
    }

    end_date = datetime.now(timezone.utc).date();
    start_date = end_date - timedelta(days=days);

    lines = [];
    lines.append("<h3>Top voices in the last " + str(days) + " days (" +
                 start_date.strftime('%Y-%m-%d') + " to " +
                 end_date.strftime('%Y-%m-%d') + ")</h3>");
    lines.append("<table>");
    lines.append("<thead><tr><th>Voice</th><th>Comments</th><th>Reviews</th><th>Issues</th><th>Active Days</th></tr></thead>");
    lines.append("<tbody>");

    for voice in voices {
        lines.append("<tr><td>" + voice.name + "</td><td>" +
                     str(voice.comments) + "</td><td>" +
                     str(voice.reviews) + "</td><td>" +
                     str(voice.issues) + "</td><td>" +
                     str(voice.active_days) + "</td></tr>");
    }
    lines.append("</tbody></table>");
    return "\n".join(lines);
}

def get_table_css() -> str {
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
    if not check_gh_cli() {
        print("# Top Voices\n\n> GitHub CLI not found or not authenticated. Unable to fetch discussion data.\n");
        return;
    }

    periods = [];
    if days_arg != None {
        periods.append(days_arg);
    }
    for p in DEFAULT_PERIODS {
        if p not in periods {
            periods.append(p);
        }
    }
    if len(periods) == 0 {
        return;
    }

    max_days = 0;
    for p in periods {
        if p > max_days {
            max_days = p;
        }
    }
    since_date = (datetime.now(timezone.utc) - timedelta(days=max_days)).strftime("%Y-%m-%dT%H:%M:%SZ");

    print("Fetching discussion data since " + since_date + "...");

    comments = fetch_comments(since_date);
    reviews = fetch_reviews(since_date);
    issues = fetch_issues(since_date);

    print("Found " + str(len(comments)) + " comments, " + str(len(reviews)) + " reviews, " + str(len(issues)) + " issues");

    html = [];
    html.append(get_table_css());
    html.append('<div class="tabcontent">');

    for days in periods {
        voices = process_voices(comments, reviews, issues, days);
        html.append(generate_html_table(voices, days));
    }

    html.append("</div>");
    print("\n".join(html));
}

with entry {
    # Parse command line arguments
    days_override = None;
    # Note: Jac CLI argument handling may vary
    # You can pass --days argument when running via jac CLI
    main(days_arg=days_override);
}
