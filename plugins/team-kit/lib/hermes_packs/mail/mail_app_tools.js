// Only account-contained mailboxes/messages; no application-level trash or Mail.delete(message).
function run(argv) {
  const a=JSON.parse(argv[0]), M=Application("Mail");
  if (!M.running()) return JSON.stringify({ok:false,error:"MAIL_APP_NOT_RUNNING",mutation_calls:0});
  const account=M.accounts().find(x=>x.emailAddresses().some(e=>e.toLowerCase()===a.account));
  if (!account) return JSON.stringify({ok:false,error:"MAIL_APP_NO_ACCOUNT",mutation_calls:0});
  function boxes() {
    const out=[];
    function walk(bs, path, depth) {
      if (depth>20) throw Error("MAIL_APP_MAILBOX_DEPTH");
      for (const b of bs) { const p=path+String(b.name()); out.push({box:b,path:p}); walk(b.mailboxes(),p+"/",depth+1); }
    }
    walk(account.mailboxes(),"",0); return out;
  }
  const tree=boxes(), findBox=p=>tree.find(b=>b.path===p);
  function boxPath(b) {
    const parts=[String(b.name())];
    for(let i=0;i<20;i++) {
      let p; try {p=b.container();if(!p) break; const n=String(p.name());if(!n) break;parts.unshift(n);b=p;} catch(e) {break;}
    }
    return parts.join("/");
  }
  const summarize=b=>({name:String(b.box.name()),path:b.path,count:b.box.messages.length});
  let calls=0, modified=0, failed=0, unknown=false, stage="preflight", changes=[];
  function answer(extra) { return JSON.stringify({ok:true,mutation_calls:calls,modified_count:modified,
    failed_count:failed,verified:null,...extra}); }
  function ruleData(r) {
    return {name:r.name(),enabled:r.enabled(),all:r.allConditionsMustBeMet(),
      conditions:r.ruleConditions().map(c=>({type:c.ruleType(),qualifier:c.qualifier(),expression:c.expression()}))};
  }
  function owned(r) {
    const d=ruleData(r);
    return d.name.startsWith("Hermes:") && d.all && d.conditions.some(c=>c.type==="account" && c.expression===String(account.id()));
  }
  function getMessage(id) {
    const n=Number(id.slice(1));
    for (const b of tree) {const hit=b.box.messages.whose({id:n})(); if(hit.length) return hit[0];}
    throw Error("MAIL_APP_NOT_FOUND");
  }
  function meta(m) {return {id:"m"+m.id(),from:m.sender(),subject:m.subject(),mailbox:m.mailbox().name(),
    read:m.readStatus(),flagged:m.flaggedStatus()};}
  function matches(m) {
    const tests=a.mail_conditions.map(c=>{
      const value=c.field==="from"?m.sender():c.field==="subject"?m.subject():m.toRecipients().map(r=>r.address()).join(",");
      return String(value).toLowerCase().includes(c.contains.toLowerCase());
    });
    return a.match==="any"?tests.some(Boolean):tests.every(Boolean);
  }
  function selection() {
    if(a.ids) return [...new Set(a.ids)].map(getMessage);
    const src=findBox(a.source_mailbox||"INBOX");
    if(!src) throw Error("MAIL_APP_SOURCE_MAILBOX_NOT_FOUND");
    const selected=[];
    for(const m of src.box.messages()) if(matches(m)) {
      selected.push(m); if(selected.length>500) throw Error("MAIL_APP_LIMIT_EXCEEDED");
    }
    return selected;
  }
  function ruleSpecs() {
    const conditions=a.mail_conditions.map(c=>({type:{from:"from header",to:"to header",subject:"subject header"}[c.field],
      qualifier:"does contain value",expression:c.contains}));
    const groups=a.match==="any"?conditions.map(c=>[c]):[conditions];
    const base="Hermes: "+a.rule_name.replace(/^Hermes:\s*/,"")+" ["+account.id()+"]";
    return groups.map((cs,i)=>({name:base+"#"+(i+1),conditions:[{type:"account",qualifier:"equal to value",expression:String(account.id())},...cs]}));
  }
  function verifyRule(r,spec) {
    const d=ruleData(r);
    return d.all && JSON.stringify(d.conditions)===JSON.stringify(spec.conditions)
      && r.shouldMoveMessage() && boxPath(r.moveMessage())===a.mailbox
      && r.moveMessage().account().id()===account.id() && r.markRead()===Boolean(a.mark_read)
      && !r.deleteMessage() && !r.forwardMessage() && !r.redirectMessage() && !r.replyText()
      && !r.shouldCopyMessage() && !r.runScript();
  }
  try {
    if(a.action==="mailboxes") return answer({mailboxes:tree.map(summarize)});
    if(a.action==="rules_list") return answer({rules:M.rules().filter(owned).map(ruleData)});
    let selected=[], specs=[], outgoing=null;
    if(["mail_move","mail_mark","mail_trash","mail_app_organize"].includes(a.action)) {
      selected=a.preview?selection():(a._snapshot.ids||[]).map(getMessage);
      if(selected.length>500) throw Error("MAIL_APP_LIMIT_EXCEEDED");
    }
    let destination=null;
    if(["mail_move","rule_create","mail_app_organize"].includes(a.action)) {
      destination=findBox(a.mailbox);
      if(!destination) throw Error("MAIL_APP_DESTINATION_NOT_FOUND: create mailbox first with approval");
    }
    if(a.action==="mail_trash") {
      // Refuse if this account has no identifiable trash. Never use Mail.trash (all accounts).
      const trash=tree.filter(b=>/^(Trash|Deleted Messages|Deleted Items|휴지통|삭제된 항목)$/i.test(b.box.name()));
      if(trash.length!==1) throw Error("MAIL_APP_ACCOUNT_TRASH_UNVERIFIED");
      destination=trash[0];
    }
    if(["rule_create","mail_app_organize"].includes(a.action)) {
      specs=ruleSpecs();
      for(const spec of specs) {
        const old=M.rules().filter(r=>r.name()===spec.name);
        if(old.length>1 || (old.length && !verifyRule(old[0],spec))) throw Error("MAIL_APP_RULE_CONFLICT");
      }
    }
    let toDelete=null;
    if(a.action==="rule_delete") {
      const hits=M.rules().filter(r=>r.name()===a.rule_name);
      if(hits.length!==1 || !owned(hits[0])) throw Error("MAIL_APP_RULE_DELETE_HERMES_ACCOUNT_ONLY");
      toDelete=hits[0];
    }
    if(["send","reply","forward"].includes(a.action)) {
      if(a.preview) {
        outgoing={to:a.to||"",cc:a.cc||"",subject:a.subject,body:a.body,original_attachments:[]};
        if(a.action!=="send") {
          const m=getMessage(a.message_id), original=meta(m);
          outgoing.original=original;
          if(a.action==="reply") outgoing.to=String(a.to||m.replyTo()||m.sender());
          // Mail's extractAddress resolves display names without interpreting them as code.
          if(a.action==="reply" && !a.to) outgoing.to=M.extractAddressFrom(outgoing.to);
          outgoing.subject=a.subject||((a.action==="reply"?"Re: ":"Fwd: ")+m.subject());
          outgoing.body=a.body+"\n\n--- "+m.sender()+" / "+m.subject()+" ---\n"+String(m.content());
          if(a.action==="forward") outgoing.original_attachments=m.mailAttachments().map(f=>({name:f.name(),size:f.fileSize()}));
        }
      } else outgoing=a._snapshot.outgoing;
    }
    if(a.preview) return answer({ids:selected.map(m=>"m"+m.id()),matched_count:selected.length,
      sample:selected.slice(0,10).map(meta),rules:specs,mailbox:a.mailbox||null,outgoing,
      existing_mailbox:a.action==="mailbox_create" && Boolean(findBox(a.mailbox))});
    if(a.action==="mailbox_create") {
      if(!findBox(a.mailbox)) {
        const parts=a.mailbox.split("/"), name=parts.pop(), parent=parts.length?findBox(parts.join("/")):null;
        if(parts.length && !parent) throw Error("MAIL_APP_PARENT_MAILBOX_NOT_FOUND");
        calls++; stage="mailbox_create";
        (parent?parent.box:account).mailboxes.push(M.Mailbox({name})); modified++;
      }
      return answer({verified:boxes().some(b=>b.path===a.mailbox),mailbox:a.mailbox});
    }
    if(toDelete) {
      calls++; stage="rule_delete"; toDelete.delete(); modified++;
      return answer({verified:!M.rules().some(r=>r.name()===a.rule_name),deleted_rule:a.rule_name});
    }
    for(const spec of specs) {
      let r=M.rules().find(r=>r.name()===spec.name);
      if(!r) {
        stage="rule_create"; calls++;
        M.rules.push(M.Rule({name:spec.name,enabled:false,allConditionsMustBeMet:true,
          shouldMoveMessage:true,moveMessage:destination.box,markRead:Boolean(a.mark_read),
          deleteMessage:false,forwardMessage:"",redirectMessage:"",replyText:"",shouldCopyMessage:false}));
        r=M.rules().find(r=>r.name()===spec.name);
        for(const c of spec.conditions) r.ruleConditions.push(M.RuleCondition({ruleType:c.type,qualifier:c.qualifier,expression:c.expression}));
        if(!verifyRule(r,spec)) throw Error("MAIL_APP_RULE_VERIFICATION_FAILED_DISABLED");
        r.enabled=true; modified++;
      }
      changes.push({rule:spec.name,verified:verifyRule(r,spec)&&r.enabled()});
    }
    for(const m of selected) {
      const sameDestination=destination && destination.box.messages.whose({id:m.id()})().length===1;
      const sameFlags=(a.read===undefined||m.readStatus()===a.read)&&(a.flagged===undefined||m.flaggedStatus()===a.flagged);
      if((a.action==="mail_mark" && sameFlags) || (destination && sameDestination && (!a.mark_read||m.readStatus()))) {
        changes.push({id:"m"+m.id(),unchanged:true,verified:true}); continue;
      }
      stage="message_mutation"; calls++;
      try {
        const rfc=m.messageId(), id="m"+m.id();
        if(a.action==="mail_mark") {
          if(a.read!==undefined) m.readStatus=a.read;
          if(a.flagged!==undefined) m.flaggedStatus=a.flagged;
        }
        if(a.action==="mail_app_organize" && a.mark_read) m.readStatus=true;
        if(destination) m.mailbox=destination.box;
        modified++;
        let verified=null;
        try {
          if(destination) {
            const found=destination.box.messages.whose({messageId:rfc})();
            if(rfc && found.length===1) verified=(!a.mark_read||found[0].readStatus());
          } else verified=(a.read===undefined||m.readStatus()===a.read)&&(a.flagged===undefined||m.flaggedStatus()===a.flagged);
        } catch(e) {}
        changes.push({id,verified});
      } catch(e) {failed++; unknown=true; changes.push({id:null,verified:null,error:"MAIL_APP_MESSAGE_RESULT_UNKNOWN"}); break;}
    }
    if(outgoing) {
      stage="compose";
      calls++;
      let message;
      if(a.action==="reply") message=M.reply(getMessage(a.message_id),{openingWindow:false,replyToAll:false});
      else if(a.action==="forward") message=M.forward(getMessage(a.message_id),{openingWindow:false});
      else {message=M.OutgoingMessage({visible:false});M.outgoingMessages.push(message);}
      message.sender=a.account; message.subject=outgoing.subject; message.content=outgoing.body;
      message.toRecipients().forEach(r=>r.delete()); message.ccRecipients().forEach(r=>r.delete()); message.bccRecipients().forEach(r=>r.delete());
      for(const s of outgoing.to.split(/[,;]/).filter(Boolean)) message.toRecipients.push(M.Recipient({address:s.trim()}));
      for(const s of outgoing.cc.split(/[,;]/).filter(Boolean)) message.ccRecipients.push(M.CcRecipient({address:s.trim()}));
      for(const file of a.attachments||[]) message.attachments.push(M.Attachment({fileName:Path(file)}));
      if((a.attachments||[]).length) delay(2+a.attachments.length);
      if(message.attachments.length!==outgoing.original_attachments.length+(a.attachments||[]).length) throw Error("MAIL_APP_ATTACH_FAILED_NOT_SENT");
      stage="send";
      const sent=message.send();
      return answer({ok:sent===true,status:sent===true?"sent":"unknown",modified_count:sent===true?1:null,
        verified:null,accepted:sent===true,stage});
    }
    const verified=changes.some(c=>c.verified===null)?null:changes.every(c=>c.verified===true);
    return answer({ok:!unknown&&verified===true,status:unknown?"partial":verified===true?"completed":"unknown",modified_count:unknown?null:modified,
      changes,verified});
  } catch(e) {
    return JSON.stringify({ok:false,error:String(e.message||e).startsWith("MAIL_APP_")?String(e.message||e):"MAIL_APP_OPERATION_FAILED",
      status:calls?"partial":"failed",stage,mutation_calls:calls,modified_count:calls?null:0,verified:null,changes,failed_count:failed});
  }
}
