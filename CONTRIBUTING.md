# Contributing to ejabberd

We'd love for you to contribute to our source code and to make ejabberd even better than it is
today! Here are the guidelines we'd like you to follow:

* [Code of Conduct](#coc)
* [Questions and Problems](#question)
* [Issues and Bugs](#issue)
* [Feature Requests](#feature)
* [Issue Submission Guidelines](#submit)
* [Pull Request Submission Guidelines](#submit-pr)
* [Signing the CLA](#cla)

## <a name="coc"></a> Code of Conduct

Help us keep ejabberd community open-minded and inclusive. Please read and follow our [Code of Conduct][coc].

## <a name="requests"></a> Questions, Bugs, Features

### <a name="question"></a> Got a Question or Problem?

Do not open issues for general support questions as we want to keep GitHub issues for bug reports
and feature requests. You've got much better chances of getting your question answered on dedicated
support platforms, the best being [Stack Overflow][stackoverflow].

Stack Overflow is a much better place to ask questions since:

- there are thousands of people willing to help on Stack Overflow
- questions and answers stay available for public viewing so your question / answer might help
  someone else
- Stack Overflow's voting system assures that the best answers are prominently visible.

To save your and our time, we will systematically close all issues that are requests for general
support and redirect people to the section you are reading right now.

Other channels for support are:
- [ejabberd Mailing List][list]
- [ejabberd XMPP room][muc]: ejabberd@conference.process-one.net

### <a name="issue"></a> Found an Issue or Bug?

If you find a bug in the source code, you can help us by submitting an issue to our
[GitHub Repository][github]. Even better, you can submit a Pull Request with a fix.

### <a name="feature"></a> Missing a Feature?

You can request a new feature by submitting an issue to our [GitHub Repository][github-issues].

If you would like to implement a new feature then consider what kind of change it is:

* **Major Changes** that you wish to contribute to the project should be discussed first in an
  [GitHub issue][github-issues] that clearly outlines the changes and benefits of the feature.
* **Small Changes** can directly be crafted and submitted to the [GitHub Repository][github]
  as a Pull Request. See the section about [Pull Request Submission Guidelines](#submit-pr).

## <a name="submit"></a> Issue Submission Guidelines

Before you submit your issue search the archive, maybe your question was already answered.

If your issue appears to be a bug, and hasn't been reported, open a new issue. Help us to maximize
the effort we can spend fixing issues and adding new features, by not reporting duplicate issues.

The "[new issue][github-new-issue]" form contains a number of prompts that you should fill out to
make it easier to understand and categorize the issue.

## <a name="submit-pr"></a> Pull Request Submission Guidelines

By submitting a pull request for a code or doc contribution, you need to have the right
to grant your contribution's copyright license to ProcessOne. Please check [ProcessOne CLA][cla]
for details.

Before you submit your pull request consider the following guidelines:

* Search [GitHub][github-pr] for an open or closed Pull Request
  that relates to your submission. You don't want to duplicate effort.
* Create the [development environment][developer-setup]
* Make your changes in a new git branch:

    ```shell
    git checkout -b my-fix-branch master
    ```
* Test your changes and, if relevant, expand the automated test suite.
* Create your patch commit, including appropriate test cases.
* If the changes affect public APIs, change or add relevant [documentation][doc-repo].
* Commit your changes using a descriptive commit message.

    ```shell
    git commit -a
    ```
  Note: the optional commit `-a` command line option will automatically "add" and "rm" edited files.

* Push your branch to GitHub:

    ```shell
    git push origin my-fix-branch
    ```

* In GitHub, send a pull request to `ejabberd:master`. This will trigger the Travis integration and run the test.
We will also notify you if you have not yet signed the [contribution agreement][cla].

* If you find that the Travis integration has failed, look into the logs on Travis to find out
if your changes caused test failures, the commit message was malformed etc. If you find that the
tests failed or times out for unrelated reasons, you can ping a team member so that the build can be
restarted.

* If we suggest changes, then:

  * Make the required updates.
  * Test your changes and test cases.
  * Commit your changes to your branch (e.g. `my-fix-branch`).
  * Push the changes to your GitHub repository (this will update your Pull Request).

    You can also amend the initial commits and force push them to the branch.

    ```shell
    git rebase master -i
    git push origin my-fix-branch -f
    ```

    This is generally easier to follow, but separate commits are useful if the Pull Request contains
    iterations that might be interesting to see side-by-side.

That's it! Thank you for your contribution!

## <a name="cla"></a> Signing the Contributor License Agreement (CLA)

Upon submmitting a Pull Request, we will ask you to sign our CLA if you haven't done
so before. It's a quick process, we promise, and you will be able to do it all online

You can read [ProcessOne Contribution License Agreement][cla] in PDF.

This is part of the legal framework of the open-source ecosystem that adds some red tape,
but protects both the contributor and the company / foundation behind the project. It also
gives us the option to relicense the code with a more permissive license in the future.


[coc]: https://github.com/processone/ejabberd/blob/master/CODE_OF_CONDUCT.md
[stackoverflow]: https://stackoverflow.com/questions/tagged/ejabberd?sort=newest
[list]: http://lists.jabber.ru/mailman/listinfo/ejabberd
[muc]: xmpp:ejabberd@conference.process-one.net
[github]: https://github.com/processone/ejabberd
[github-issues]: https://github.com/processone/ejabberd/issues
[github-new-issue]: https://github.com/processone/ejabberd/issues/new
[github-pr]: https://github.com/processone/ejabberd/pulls
[doc-repo]: https://github.com/processone/docs.ejabberd.im
[developer-setup]: https://docs.ejabberd.im/developer/
[cla]: https://www.process-one.net/resources/ejabberd-cla.pdf
[license]: https://github.com/processone/ejabberd/blob/master/COPYING
