"use client";

import { memo, useState, useCallback } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { Prism as SyntaxHighlighter } from "react-syntax-highlighter";
import { atomDark } from "react-syntax-highlighter/dist/esm/styles/prism";

/* ------------------------------------------------------------------ */
/*  Copy button — shared by code blocks and messages                  */
/* ------------------------------------------------------------------ */

function CopyButton({
  text,
  className = "",
  label,
}: {
  text: string;
  className?: string;
  label?: string;
}) {
  const [copied, setCopied] = useState(false);

  const copy = useCallback(() => {
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 1200);
  }, [text]);

  return (
    <button
      onClick={copy}
      className={`flex items-center gap-1 text-xs transition-colors ${
        copied
          ? "text-green-400"
          : "text-neutral-400 hover:text-white"
      } ${className}`}
      aria-label={copied ? "Copied" : "Copy"}
    >
      {copied ? (
        <svg className="w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
          <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
        </svg>
      ) : (
        <svg className="w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
          <rect x="9" y="9" width="13" height="13" rx="2" />
          <path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1" />
        </svg>
      )}
      {label && <span>{copied ? "Copied" : label}</span>}
    </button>
  );
}

/* ------------------------------------------------------------------ */
/*  Code block with header, language tag, and copy button             */
/* ------------------------------------------------------------------ */

function CodeBlock({
  language,
  children,
}: {
  language: string | undefined;
  children: string;
}) {
  const lang = language?.replace(/^language-/, "") || "";
  const code = children.replace(/\n$/, "");

  return (
    <div className="group relative rounded-lg overflow-hidden my-2 bg-[#1d1f21] border border-white/[0.08]">
      {/* Header bar */}
      <div className="flex items-center justify-between px-3 py-1.5 bg-white/[0.04] border-b border-white/[0.06] text-[11px]">
        <span className="text-neutral-400 font-mono">{lang || "code"}</span>
        <CopyButton text={code} />
      </div>

      {/* Code */}
      <div className="overflow-x-auto">
        <SyntaxHighlighter
          language={lang || "text"}
          style={atomDark}
          customStyle={{
            margin: 0,
            padding: "12px 16px",
            background: "transparent",
            fontSize: "13px",
            lineHeight: "1.5",
          }}
          codeTagProps={{
            style: { fontFamily: "ui-monospace, 'SF Mono', Menlo, monospace" },
          }}
        >
          {code}
        </SyntaxHighlighter>
      </div>
    </div>
  );
}

/* ------------------------------------------------------------------ */
/*  Markdown renderer — matches desktop SelectableMarkdown styling    */
/* ------------------------------------------------------------------ */

interface MarkdownMessageProps {
  text: string;
  sender: "user" | "ai";
}

export const MarkdownMessage = memo(function MarkdownMessage({
  text,
  sender,
}: MarkdownMessageProps) {
  const isUser = sender === "user";

  return (
    <div className="markdown-content">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          // Code blocks & inline code
          code({ className, children, ...props }) {
            const match = /language-(\w+)/.exec(className || "");
            const codeStr = String(children);

            // Multi-line → full code block
            if (codeStr.includes("\n") || match) {
              return (
                <CodeBlock language={match?.[1]}>
                  {codeStr}
                </CodeBlock>
              );
            }

            // Inline code
            return (
              <code
                className={`px-1.5 py-0.5 rounded text-[13px] font-mono ${
                  isUser
                    ? "bg-black/20 text-white"
                    : "bg-white/[0.08] text-purple-300"
                }`}
                {...props}
              >
                {children}
              </code>
            );
          },

          // Wrap pre to avoid double-nesting
          pre({ children }) {
            return <>{children}</>;
          },

          // Paragraphs
          p({ children }) {
            return <p className="mb-2 last:mb-0 leading-relaxed">{children}</p>;
          },

          // Headers — rendered as bold text like desktop
          h1({ children }) {
            return <p className="mb-2 last:mb-0 font-bold text-base">{children}</p>;
          },
          h2({ children }) {
            return <p className="mb-2 last:mb-0 font-bold text-[15px]">{children}</p>;
          },
          h3({ children }) {
            return <p className="mb-2 last:mb-0 font-semibold">{children}</p>;
          },

          // Lists
          ul({ children }) {
            return <ul className="mb-2 last:mb-0 ml-4 space-y-0.5 list-disc">{children}</ul>;
          },
          ol({ children }) {
            return <ol className="mb-2 last:mb-0 ml-4 space-y-0.5 list-decimal">{children}</ol>;
          },
          li({ children }) {
            return <li className="leading-relaxed">{children}</li>;
          },

          // Links
          a({ children, href }) {
            return (
              <a
                href={href}
                target="_blank"
                rel="noopener noreferrer"
                className={isUser ? "text-white underline" : "text-purple-400 hover:text-purple-300 underline"}
              >
                {children}
              </a>
            );
          },

          // Blockquote
          blockquote({ children }) {
            return (
              <blockquote className="border-l-2 border-white/20 pl-3 my-2 text-neutral-300 italic">
                {children}
              </blockquote>
            );
          },

          // Horizontal rule
          hr() {
            return <hr className="border-white/10 my-3" />;
          },

          // Tables
          table({ children }) {
            return (
              <div className="overflow-x-auto my-2">
                <table className="min-w-full text-sm border-collapse">{children}</table>
              </div>
            );
          },
          th({ children }) {
            return (
              <th className="text-left px-3 py-1.5 border-b border-white/10 font-semibold text-neutral-300">
                {children}
              </th>
            );
          },
          td({ children }) {
            return (
              <td className="px-3 py-1.5 border-b border-white/[0.05]">{children}</td>
            );
          },

          // Strong & em
          strong({ children }) {
            return <strong className="font-semibold">{children}</strong>;
          },
          em({ children }) {
            return <em className="italic">{children}</em>;
          },

          // Strikethrough
          del({ children }) {
            return <del className="line-through text-neutral-400">{children}</del>;
          },
        }}
      >
        {text}
      </ReactMarkdown>
    </div>
  );
});

/* ------------------------------------------------------------------ */
/*  Exports                                                           */
/* ------------------------------------------------------------------ */

export { CopyButton };
