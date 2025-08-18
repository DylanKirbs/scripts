#!/usr/bin/env python3

"""
Since this script is intended to clone multiple repositories, you must set up an SSH multiplexing
configuration to avoid entering your password for each clone operation. This can be done by adding
the following to your SSH config file:
```
Host gitolite.cs.sun.ac.za
    ControlMaster auto
    ControlPath ~/.ssh/controlmasters/%r@%h:%p
    ControlPersist 600
```
Ensure the directory `~/.ssh/controlmasters/` exists.
"""

from argparse import ArgumentParser, REMAINDER
from git import Repo
from pathlib import Path
from termcolor import colored
from tqdm import tqdm
from tqdm.contrib.logging import logging_redirect_tqdm
import logging
import sys

USER = "rw244-2025"
TEMPLATE_REPO_URL = "{user}@gitolite.cs.sun.ac.za:{su_number}/{project_name}"
CLONE_DIR = Path("repos").resolve()


class ColouredFormatter(logging.Formatter):
    """
    A logging formatter that highlights specified text.

    :author: D. Kirby
    """

    def __init__(self, *args, highlights: dict = {}, **kwargs):
        """
        Initialize the formatter.

        Example usage:
        >>> formatter = ColouredFormatter('%(levelname)-8s| %(message)s', highlights={'INFO': 'green'})

        :param highlights: The dictionary of words and colours to highlight them, defaults to {}
        :type highlights: dict, optional

        The args and kwargs are passed to the superclass. See [`logging.Formatter`](https://docs.python.org/3/library/logging.html#logging.Formatter) for more information.
        """
        super().__init__(*args, **kwargs)

        # Precompute the replacements
        self.replacer = {}
        for text, color in highlights.items():
            self.replacer[text] = colored(text, color)

    def format(self, record: logging.LogRecord) -> str:
        out = super().format(record)
        for text, highlight in self.replacer.items():
            out = out.replace(text, highlight)
        return out


def repo_2_su(repo: Repo) -> str:
    return Path(str(repo.working_tree_dir)).name


class ProjectRepos:
    def __init__(self, su_numbers: set[str], project_name: str, dry_run=False):

        # Initialize instance variables
        self.su_numbers = su_numbers
        self.project_name = project_name
        self.repo_dir = CLONE_DIR / project_name

        self.dry_run = dry_run

        # Setup
        self.repos: set[Repo] = set()
        self.locate()
        self.repo_dir.mkdir(parents=True, exist_ok=True)

        # Subcommands
        self._subcommands = {
            "clone": self.clone,
            "pull": self.pull,
            "switch": self.switch,
            "export-commits": self.export_commits,
            "checkout-commits": self.checkout_commits,
        }

    def run(self, name):
        if name in self._subcommands:
            return self._subcommands[name]
        raise AttributeError(f"Unknown subcommand: {name}")

    def locate(self):
        """
        Loads the existing directories into self.repos.
        """

        self.repos = set(
            Repo(repo_dir)
            for repo_dir in self.repo_dir.iterdir()
            if repo_dir.is_dir() and (repo_dir / ".git").exists()
        )

        if len(self.repos) == 0:
            logging.warning("No repositories found. Please clone first.")
        else:
            logging.info(
                f"Located {len(self.repos)}/{len(self.su_numbers)} repositories in {self.repo_dir.resolve()}"
            )

    def clone(self):
        """
        Clone the repositories for the specified student numbers and project name.
        Only non-existing repositories will be cloned.
        """

        if len(self.repos) > 0:
            logging.warning(
                "Only non-existing repositories will be cloned. If you wish to update the existing repositories, use 'pull' instead"
            )

        su_numbers = self.su_numbers - set(repo_2_su(repo) for repo in self.repos)

        for su_number in tqdm(su_numbers):
            if self.dry_run:
                logging.info(
                    f"Dry run: {TEMPLATE_REPO_URL.format(su_number=su_number, project_name=self.project_name, user=USER)}"
                )
                continue

            try:
                repo = Repo.clone_from(
                    TEMPLATE_REPO_URL.format(
                        su_number=su_number, project_name=self.project_name, user=USER
                    ),
                    self.repo_dir / su_number,
                )
                self.repos.add(repo)
            except Exception as e:
                tqdm.write(
                    f"An error occurred while cloning the repository for {su_number}: {e}",
                    file=sys.stderr,
                )

    def pull(self):
        """
        Pull the latest changes for the specified student numbers and project name.

        Only existing repositories will be pulled. A set containing all of the repos is returned.
        """

        if len(self.repos) == 0:
            logging.warning(
                "No repositories found. If you wish to clone new repos, use 'clone' instead"
            )

        for repo in tqdm(self.repos):
            if self.dry_run:
                logging.info(f"Dry run [pull]: {repo_2_su(repo)}")
                continue

            try:
                repo.git.pull()
            except Exception as e:
                tqdm.write(
                    f"An error occurred while pulling the repository for {repo_2_su(repo)}: {e}",
                    file=sys.stderr,
                )

    def switch(self, branch_like: str):

        successes = set()
        for repo in tqdm(self.repos):
            if self.dry_run:
                logging.info(f"Dry run [switch]: {repo_2_su(repo)}")
                continue

            try:
                repo.git.checkout(branch_like)
                successes.add(repo)
            except Exception as e:
                tqdm.write(
                    f"An error occurred while switching branches for {repo_2_su(repo)}: {e}",
                    file=sys.stderr,
                )

        logging.info(
            f"Successfully switched branches for {len(successes)}/{len(self.repos)}/{len(self.su_numbers)} switched/total repos/students."
        )
        self._export(successes, "switched_repos.csv")

    def _export(self, repos, out_file):
        """
        Export the specified repositories to a file.
        """
        with open(out_file, "w") as f:
            for repo in tqdm(repos):
                f.write(f"{repo_2_su(repo)},{repo.head.commit.hexsha}\n")

    def export_commits(self, out_file: str):
        """
        Export the current commit hash for each repository to a csv file.

        :param out_file: The output file to write the commit hashes to.
        """

        self._export(self.repos, out_file)

    def checkout_commits(self, in_file: str):
        """
        Checkout the commits specified in the input file.

        :param in_file: The input file containing student numbers and commit hashes.
        """

        checked = set()
        with open(in_file, "r") as f:
            f.readline()  # Skip header line
            for line in tqdm(f.readlines()):
                su_number, commit_hash = line.strip().split(",")
                repo = self.repo_dir / su_number
                if not repo.exists():
                    logging.warning(f"Repository for {su_number} does not exist.")
                    continue

                try:
                    r = Repo(repo)
                    r.git.checkout(commit_hash)
                    checked.add(su_number)
                except Exception as e:
                    tqdm.write(
                        f"An error occurred while checking out {commit_hash} for {su_number}: {e}",
                        file=sys.stderr,
                    )

        missing_students = su_numbers - checked
        extra_students = checked - su_numbers
        logging.info(
            f"Missing students: {missing_students}, Extra students: {extra_students}"
        )


if __name__ == "__main__":

    parser = ArgumentParser(
        description="Clone Git repositories for a project from a template URL."
    )

    # Flags
    parser.add_argument(
        "--dry-run",
        help="If set, will not perform any cloning, just print the URLs.",
        action="store_true",
    )
    parser.add_argument(
        "--log-level",
        help="Set the logging level.",
        type=str,
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        default="INFO",
    )

    # Positional Args
    parser.add_argument(
        "student_numbers_file",
        help="A newline-separated list of student numbers to clone repositories for.",
        type=str,
    )
    parser.add_argument(
        "project_name",
        help="Name of the project to clone repositories for.",
        type=str,
    )
    parser.add_argument(
        "subcommand",
        help="Name of the subcommand to run.",
        type=str,
    )
    parser.add_argument(
        "subcommand_args",
        help="Arguments for the subcommand.",
        nargs=REMAINDER,
    )

    args = parser.parse_args()

    # Logging

    logging.basicConfig(level=logging.INFO)
    formatter = ColouredFormatter(
        "%(levelname)-8s| %(message)s",
        highlights={
            # Log levels
            "DEBUG": "cyan",
            "INFO": "green",
            "WARNING": "yellow",
            "ERROR": "red",
            "EXCEPTION": "red",
            "CRITICAL": "red",
        },
    )
    logging.getLogger().handlers[0].setFormatter(formatter)

    # Main execution

    su_numbers = set()
    with open(args.student_numbers_file, "r") as f:
        su_numbers = {line.strip() for line in f if line.strip()}

    projects = ProjectRepos(su_numbers, args.project_name, dry_run=args.dry_run)
    with logging_redirect_tqdm():
        projects.run(args.subcommand)(*args.subcommand_args)

    sys.exit(0)
