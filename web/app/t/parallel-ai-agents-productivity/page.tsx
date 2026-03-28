import type { Metadata } from "next";
import { CTAButton } from "@/components/cta-button";

export const metadata: Metadata = {
  title: "Running Parallel AI Agents: A Practical Guide to Multi-Agent Productivity",
  description:
    "Learn how to run multiple AI agents in parallel for real productivity gains. Covers task decomposition, independent agent workflows, and avoiding the coordination trap.",
  openGraph: {
    title: "Running Parallel AI Agents: A Practical Guide",
    description:
      "How to actually get work done with multiple AI agents running simultaneously — without the coordination overhead.",
    type: "article",
    url: "https://fazm.ai/t/parallel-ai-agents-productivity",
  },
  twitter: {
    card: "summary_large_image",
    title: "Running Parallel AI Agents: A Practical Guide",
    description:
      "How to actually get work done with multiple AI agents running simultaneously.",
  },
};

export default function ParallelAIAgentsGuide() {
  return (
    <article className="max-w-3xl mx-auto px-6 py-16">
      {/* Hero */}
      <header className="mb-12">
        <h1 className="text-4xl font-bold tracking-tight mb-4">
          Running Parallel AI Agents: A Practical Guide to Multi-Agent
          Productivity
        </h1>
        <p className="text-lg text-gray-600">
          The multi-agent hype is everywhere, but most production setups fail
          because they over-coordinate. Here&apos;s how to actually make
          parallel agents work.
        </p>
      </header>

      {/* Table of Contents */}
      <nav className="bg-gray-50 rounded-lg p-6 mb-12">
        <h2 className="text-sm font-semibold uppercase text-gray-500 mb-3">
          Contents
        </h2>
        <ol className="space-y-2 text-blue-600">
          <li>
            <a href="#why-parallel" className="hover:underline">
              1. Why Parallel Agents Beat Sequential Workflows
            </a>
          </li>
          <li>
            <a href="#decomposition" className="hover:underline">
              2. Task Decomposition: The Make-or-Break Skill
            </a>
          </li>
          <li>
            <a href="#independence" className="hover:underline">
              3. Keeping Agents Independent
            </a>
          </li>
          <li>
            <a href="#coordination-trap" className="hover:underline">
              4. The Inter-Agent Coordination Trap
            </a>
          </li>
          <li>
            <a href="#practical-setup" className="hover:underline">
              5. Practical Setup: Running 5+ Agents Daily
            </a>
          </li>
          <li>
            <a href="#tools" className="hover:underline">
              6. Tools That Make This Work
            </a>
          </li>
          <li>
            <a href="#when-single" className="hover:underline">
              7. When to Use a Single Agent Instead
            </a>
          </li>
        </ol>
      </nav>

      {/* Section 1 */}
      <section id="why-parallel" className="mb-12">
        <h2 className="text-2xl font-bold mb-4">
          1. Why Parallel Agents Beat Sequential Workflows
        </h2>
        <p className="text-gray-700 mb-4">
          The promise of multi-agent systems is throughput. Instead of one agent
          working through a backlog of tasks one by one, you spin up five agents
          and get five things done simultaneously. In practice, this can cut
          development time by 3-5x for the right kinds of work.
        </p>
        <p className="text-gray-700 mb-4">
          But the key phrase is &quot;right kinds of work.&quot; Parallel agents
          shine when tasks are naturally independent — different features,
          different files, different repos. They fall apart when you try to make
          them collaborate on a single tightly-coupled task.
        </p>
        <div className="bg-blue-50 border-l-4 border-blue-500 p-4 rounded">
          <p className="text-gray-800">
            <strong>The 90% rule:</strong> In failed multi-agent deployments,
            roughly 90% of total compute goes to inter-agent messaging and
            coordination — not actual work. The fix isn&apos;t better
            coordination protocols. It&apos;s eliminating the need to coordinate
            at all.
          </p>
        </div>
      </section>

      {/* Section 2 */}
      <section id="decomposition" className="mb-12">
        <h2 className="text-2xl font-bold mb-4">
          2. Task Decomposition: The Make-or-Break Skill
        </h2>
        <p className="text-gray-700 mb-4">
          The entire multi-agent workflow lives or dies on how you split tasks.
          Good decomposition means each agent gets:
        </p>
        <ul className="list-disc pl-6 space-y-2 text-gray-700 mb-4">
          <li>
            <strong>A clear, self-contained objective</strong> — &quot;Add the
            payment webhook handler&quot; not &quot;work on payments&quot;
          </li>
          <li>
            <strong>All necessary context upfront</strong> — relevant files, API
            specs, type definitions
          </li>
          <li>
            <strong>No dependencies on other agents&apos; output</strong> — if
            Agent A needs Agent B&apos;s result, your decomposition is wrong
          </li>
          <li>
            <strong>Isolated file scope</strong> — two agents editing the same
            file creates merge conflicts and race conditions
          </li>
        </ul>
        <p className="text-gray-700">
          Think of it like assigning tickets to developers. You wouldn&apos;t
          give two developers the same file and say &quot;figure it out.&quot;
          You&apos;d split the work along natural boundaries. Same principle
          applies to agents.
        </p>
      </section>

      {/* Section 3 */}
      <section id="independence" className="mb-12">
        <h2 className="text-2xl font-bold mb-4">
          3. Keeping Agents Independent
        </h2>
        <p className="text-gray-700 mb-4">
          Independence isn&apos;t just about task assignment — it&apos;s about
          runtime isolation. Each agent should operate as if it&apos;s the only
          one running. Strategies that work:
        </p>

        <div className="overflow-x-auto mb-4">
          <table className="w-full border-collapse border border-gray-200">
            <thead>
              <tr className="bg-gray-50">
                <th className="border border-gray-200 px-4 py-2 text-left">
                  Strategy
                </th>
                <th className="border border-gray-200 px-4 py-2 text-left">
                  How It Works
                </th>
                <th className="border border-gray-200 px-4 py-2 text-left">
                  Best For
                </th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td className="border border-gray-200 px-4 py-2 font-medium">
                  Git worktrees
                </td>
                <td className="border border-gray-200 px-4 py-2">
                  Each agent works in its own worktree branch
                </td>
                <td className="border border-gray-200 px-4 py-2">
                  Code changes across multiple features
                </td>
              </tr>
              <tr>
                <td className="border border-gray-200 px-4 py-2 font-medium">
                  Separate directories
                </td>
                <td className="border border-gray-200 px-4 py-2">
                  Agents assigned to non-overlapping file paths
                </td>
                <td className="border border-gray-200 px-4 py-2">
                  Monorepo with clear module boundaries
                </td>
              </tr>
              <tr>
                <td className="border border-gray-200 px-4 py-2 font-medium">
                  Task-level isolation
                </td>
                <td className="border border-gray-200 px-4 py-2">
                  Each agent handles a fully independent task (research, testing,
                  writing)
                </td>
                <td className="border border-gray-200 px-4 py-2">
                  Mixed workloads (not all code)
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p className="text-gray-700">
          The common mistake is building a &quot;manager agent&quot; that
          coordinates others. This adds latency, eats tokens on routing
          decisions, and creates a single point of failure. If you need a
          manager, your tasks aren&apos;t independent enough.
        </p>
      </section>

      {/* Section 4 */}
      <section id="coordination-trap" className="mb-12">
        <h2 className="text-2xl font-bold mb-4">
          4. The Inter-Agent Coordination Trap
        </h2>
        <p className="text-gray-700 mb-4">
          Here&apos;s the pattern that kills multi-agent setups: Agent A finishes
          step 1, sends a message to Agent B, which processes it and sends to
          Agent C. Each handoff introduces:
        </p>
        <ul className="list-disc pl-6 space-y-2 text-gray-700 mb-4">
          <li>
            <strong>Serialization overhead</strong> — converting context to
            messages and back (~500-2000 tokens per handoff)
          </li>
          <li>
            <strong>Context loss</strong> — each agent only sees its message,
            not the full picture
          </li>
          <li>
            <strong>Error propagation</strong> — Agent B misinterprets Agent
            A&apos;s output, Agent C builds on the misinterpretation
          </li>
          <li>
            <strong>Debugging nightmares</strong> — when something goes wrong,
            tracing through 3 agents&apos; logs is painful
          </li>
        </ul>
        <p className="text-gray-700">
          If Agent A needs to check with Agent B before proceeding, that&apos;s
          usually a sign you should have given one agent the full context from
          the start. A single agent with complete context almost always
          outperforms a chain of agents passing partial information.
        </p>
      </section>

      {/* Section 5 */}
      <section id="practical-setup" className="mb-12">
        <h2 className="text-2xl font-bold mb-4">
          5. Practical Setup: Running 5+ Agents Daily
        </h2>
        <p className="text-gray-700 mb-4">
          A typical parallel workflow for a development team looks like this:
        </p>
        <div className="bg-gray-50 rounded-lg p-4 mb-4 font-mono text-sm">
          <p className="text-gray-600 mb-2"># Terminal 1: Feature work</p>
          <p className="text-gray-800 mb-3">
            agent &quot;Add Stripe webhook handler to /api/webhooks&quot;
          </p>
          <p className="text-gray-600 mb-2"># Terminal 2: Bug fix</p>
          <p className="text-gray-800 mb-3">
            agent &quot;Fix race condition in session refresh logic&quot;
          </p>
          <p className="text-gray-600 mb-2"># Terminal 3: Tests</p>
          <p className="text-gray-800 mb-3">
            agent &quot;Write integration tests for the auth flow&quot;
          </p>
          <p className="text-gray-600 mb-2"># Terminal 4: Documentation</p>
          <p className="text-gray-800 mb-3">
            agent &quot;Update API docs for the new endpoints&quot;
          </p>
          <p className="text-gray-600 mb-2"># Terminal 5: Research</p>
          <p className="text-gray-800">
            agent &quot;Investigate memory leak in the dashboard component&quot;
          </p>
        </div>
        <p className="text-gray-700 mb-4">
          Each agent runs in its own terminal, its own git worktree (or
          non-overlapping files), and has its own context. No shared state, no
          message passing. You review the results when they&apos;re done, just
          like reviewing PRs from different developers.
        </p>
        <p className="text-gray-700">
          The key metrics to track: <strong>completion rate</strong> (what % of
          tasks finish successfully without intervention),{" "}
          <strong>conflict rate</strong> (how often do agents step on each
          other), and <strong>wall-clock time</strong> (total time from start to
          all tasks done).
        </p>
      </section>

      {/* Section 6 */}
      <section id="tools" className="mb-12">
        <h2 className="text-2xl font-bold mb-4">
          6. Tools That Make This Work
        </h2>
        <p className="text-gray-700 mb-4">
          The tooling landscape for parallel agents is still early, but a few
          approaches stand out:
        </p>
        <ul className="list-disc pl-6 space-y-3 text-gray-700 mb-4">
          <li>
            <strong>Terminal-based agents (Claude Code, Aider, etc.)</strong> —
            run multiple instances in tmux or separate terminals. Simple and
            effective.
          </li>
          <li>
            <strong>Desktop AI agents</strong> — tools like{" "}
            <a
              href="https://fazm.ai"
              className="text-blue-600 hover:underline"
            >
              Fazm
            </a>{" "}
            that control your entire OS (browser, apps, files) through
            accessibility APIs, letting agents handle non-code tasks too.
          </li>
          <li>
            <strong>Git worktree managers</strong> — automate creating and
            merging worktrees so each agent has a clean, isolated copy of the
            repo.
          </li>
          <li>
            <strong>MCP (Model Context Protocol) servers</strong> — give agents
            structured access to external tools without custom integration per
            tool.
          </li>
        </ul>
        <p className="text-gray-700">
          The ideal setup combines a terminal agent for code with a desktop
          agent for everything else — email, browser research, document editing,
          spreadsheet work. This way your code agents stay focused while other
          agents handle the non-code parts of shipping.
        </p>
      </section>

      {/* Section 7 */}
      <section id="when-single" className="mb-12">
        <h2 className="text-2xl font-bold mb-4">
          7. When to Use a Single Agent Instead
        </h2>
        <p className="text-gray-700 mb-4">
          Multi-agent isn&apos;t always the answer. Use a single agent when:
        </p>
        <ul className="list-disc pl-6 space-y-2 text-gray-700 mb-4">
          <li>The task requires deep context across many files</li>
          <li>
            Steps are strictly sequential (each depends on the previous)
          </li>
          <li>
            The codebase is small enough that one agent can hold it all in
            context
          </li>
          <li>
            You need consistency in style/approach across the changes
          </li>
        </ul>
        <p className="text-gray-700">
          The best practitioners switch fluidly between single-agent deep work
          and multi-agent parallel execution depending on what the task
          actually requires. There&apos;s no universal answer — just the right
          tool for each job.
        </p>
      </section>

      {/* CTA */}
      <section className="bg-gradient-to-r from-blue-600 to-blue-800 rounded-2xl p-8 text-center text-white">
        <h2 className="text-2xl font-bold mb-3">
          Want an agent that handles more than just code?
        </h2>
        <p className="text-blue-100 mb-6">
          Fazm is an open-source macOS AI agent that controls your browser,
          documents, and apps — so you can run it alongside your coding agents
          for full-stack productivity.
        </p>
        <CTAButton href="https://github.com/m13v/fazm" page="/t/parallel-ai-agents-productivity">
          View on GitHub
        </CTAButton>
      </section>

      {/* Footer */}
      <footer className="mt-16 pt-8 border-t border-gray-200 text-center text-sm text-gray-500">
        <p>
          <a href="https://fazm.ai" className="hover:underline">
            fazm.ai
          </a>{" "}
          — Open-source desktop AI agent for macOS
        </p>
      </footer>
    </article>
  );
}
